import Foundation

/// `/bin/sh` scripts standing in for a real agent CLI in ``CLIProbeTests``, talking over
/// ``StubProbeAdapter``'s `argv`/stdout convention: `$1` is the instruction, `$2` the pass, `$3`
/// the resumed session (empty when starting fresh). Every script also handles a lone `--version`
/// invocation, which ``CLIProbe`` runs separately from a dispatch.
enum StubProbeCLI {
    /// Completes every pass; echoes the nonce it is asked for, resumes sessions, and actually runs
    /// the hold script a worker pass is told to run.
    static let healthy = shell(
        """
        if [ "$1" = "--version" ]; then
            echo "stub-cli 9.9.9"
            exit 0
        fi
        instruction="$1"
        pass="$2"
        resume="$3"
        case "$pass" in
            architect)
                if [ -n "$resume" ]; then
                    prior=$(cat .yh-probe-nonce 2>/dev/null)
                    printf 'SESSION:stub-session\\n'
                    printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,\
        "outcome":"failed","reason":"%s"}\\n' "$prior"
                else
                    nonce=$(echo "$instruction" | grep -o 'yh-probe-[0-9a-f]\\{12\\}')
                    echo "$nonce" > .yh-probe-nonce
                    printf 'SESSION:stub-session\\n'
                    printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,\
        "outcome":"failed","reason":"%s"}\\n' "$nonce"
                fi
                ;;
            worker)
                variant=$(echo "$instruction" | grep -o 'yh-probe-hold.sh [a-z]*' | awk '{print $2}')
                sh yh-probe-hold.sh "$variant"
                printf 'RESULT:{"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
        "commit":"0123456789abcdef0123456789abcdef01234567","summary":"stub"}\\n'
                ;;
        esac
        """
    )

    /// Exits 1 on every pass, as if the CLI needed interactive login.
    static let notLoggedIn = shell(
        """
        if [ "$1" = "--version" ]; then
            echo "stub-cli 9.9.9"
            exit 0
        fi
        echo "Not logged in \\xc2\\xb7 Please run /login" >&2
        exit 1
        """
    )

    /// Never exits on a dispatch: simulates a CLI blocked on an interactive prompt.
    static let hangs = shell(
        """
        if [ "$1" = "--version" ]; then
            echo "stub-cli 9.9.9"
            exit 0
        fi
        sleep 60
        """
    )

    /// The worker pass detaches the hold script into a new session (`setsid`) before running it, so
    /// it escapes the CLI's process group and survives SIGTERM/SIGKILL to that group.
    static let escapes = shell(
        """
        if [ "$1" = "--version" ]; then
            echo "stub-cli 9.9.9"
            exit 0
        fi
        instruction="$1"
        pass="$2"
        resume="$3"
        case "$pass" in
            architect)
                if [ -n "$resume" ]; then
                    prior=$(cat .yh-probe-nonce 2>/dev/null)
                    printf 'SESSION:stub-session\\n'
                    printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,\
        "outcome":"failed","reason":"%s"}\\n' "$prior"
                else
                    nonce=$(echo "$instruction" | grep -o 'yh-probe-[0-9a-f]\\{12\\}')
                    echo "$nonce" > .yh-probe-nonce
                    printf 'SESSION:stub-session\\n'
                    printf 'RESULT:{"schema":"yellowhammer.result.architect","version":1,\
        "outcome":"failed","reason":"%s"}\\n' "$nonce"
                fi
                ;;
            worker)
                variant=$(echo "$instruction" | grep -o 'yh-probe-hold.sh [a-z]*' | awk '{print $2}')
                echo $$ > .yh-probe-leader-"$variant"
                perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV' /bin/sh yh-probe-hold.sh "$variant" &
                wait
                ;;
        esac
        """
    )

    /// Exits 0 on the architect pass but never writes a `RESULT:` line, so no result file appears.
    static let cleanExitNoResult = shell(
        """
        if [ "$1" = "--version" ]; then
            echo "stub-cli 9.9.9"
            exit 0
        fi
        exit 0
        """
    )

    private static func shell(_ body: String) -> String {
        "#!/bin/sh\n\(body)\n"
    }

    static func write(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
