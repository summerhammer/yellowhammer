import io
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import release_gate  # noqa: E402

#: A fresh Installation token pair (P17.8): the Keychain's own JSON shape.
FRESH_PAIR = {
    "access_token": "token",
    "refresh_token": "refresh",
    "expires_at": (datetime.now(timezone.utc) + timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ"),
}


def make_summary_lines(results):
    """`results`: [(number, title, passed)] — renders the lines `print_summary` would."""
    lines = ["", release_gate.SUMMARY_HEADER]
    for number, title, passed in results:
        lines.append(f"{'PASS' if passed else 'FAIL'} [{number}] {title}")
        if not passed:
            lines.append("    FAIL: something went wrong")
    return lines


def all_scenarios_summary(passed_numbers=None):
    passed_numbers = set(passed_numbers) if passed_numbers is not None else set(release_gate.ALL_SCENARIOS)
    return [
        (number, f"Scenario {number}", number in passed_numbers) for number in release_gate.ALL_SCENARIOS
    ]


class FakeProcess:
    def __init__(self, lines, returncode):
        self.stdout = io.StringIO("\n".join(lines) + ("\n" if lines else ""))
        self._returncode = returncode
        self.returncode = None

    def wait(self):
        self.returncode = self._returncode
        return self._returncode


class FakeTransport:
    """Answers every GraphQL POST with a fixed url per issue id."""

    def __init__(self, urls=None, fail_ids=frozenset()):
        self.urls = urls or {}
        self.fail_ids = fail_ids

    def post_json(self, url, payload, headers=None):
        variables = payload.get("variables", {})
        issue_id = variables.get("id")
        if issue_id in self.fail_ids:
            return 200, json.dumps({"errors": [{"message": "boom"}]})
        node_url = self.urls.get(issue_id, f"https://linear.app/issue/{issue_id}")
        return 200, json.dumps({"data": {"issue": {"url": node_url}}})


def write_journal_db(path, rows):
    """`rows`: [(night_start, night_card_issue_id)]."""
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(str(path))
    connection.execute(
        "CREATE TABLE night (id INTEGER PRIMARY KEY, night_start TEXT, night_card_issue_id TEXT)"
    )
    for index, (night_start, issue_id) in enumerate(rows, start=1):
        connection.execute(
            "INSERT INTO night (id, night_start, night_card_issue_id) VALUES (?, ?, ?)",
            (index, night_start, issue_id),
        )
    connection.commit()
    connection.close()


class ParseSummaryTests(unittest.TestCase):
    def test_parses_pass_and_fail_lines_after_the_summary_header(self):
        lines = make_summary_lines([(1, "Title one", True), (2, "Title two", False)])
        results = release_gate.parse_summary(lines)
        self.assertEqual(
            results,
            [
                {"number": 1, "title": "Title one", "passed": True},
                {"number": 2, "title": "Title two", "passed": False},
            ],
        )

    def test_ignores_pass_fail_lines_before_the_summary_header(self):
        lines = [
            "=== Scenario 1: Title one ===",
            "PASS [1] some check that happens to look like a summary line",
        ] + make_summary_lines([(1, "Title one", True)])
        results = release_gate.parse_summary(lines)
        self.assertEqual(results, [{"number": 1, "title": "Title one", "passed": True}])

    def test_no_summary_header_yields_no_results(self):
        self.assertEqual(release_gate.parse_summary(["nothing here"]), [])

    def test_indented_failure_detail_lines_are_not_parsed_as_results(self):
        lines = make_summary_lines([(1, "Title one", False)])
        results = release_gate.parse_summary(lines)
        self.assertEqual(results, [{"number": 1, "title": "Title one", "passed": False}])


class NightCardLinkTests(unittest.TestCase):
    def test_link_falls_back_to_bare_id_on_fetch_failure(self):
        transport = FakeTransport(fail_ids={"issue-2"})
        with tempfile.TemporaryDirectory() as configuration_directory:
            configuration_directory = Path(configuration_directory)
            (configuration_directory / "config.toml").write_text(('[board.linear.connections.scratch]\n'
                'credential = "keychain:linear-scratch"\nworkspace = "ws-1"\nyellowhammer_identity = "app-1"\n'))
            with mock.patch.object(
                release_gate.scratch_linear, "keychain_token_pair", return_value=FRESH_PAIR
            ):
                links = release_gate.resolve_night_card_links(
                    ["issue-1", "issue-2"], configuration_directory=configuration_directory,
                    transport=transport,
                )
        self.assertEqual(links["issue-1"], "https://linear.app/issue/issue-1")
        self.assertEqual(links["issue-2"], "issue-2")

    def test_no_credential_falls_back_every_issue_to_its_bare_id(self):
        with tempfile.TemporaryDirectory() as configuration_directory:
            configuration_directory = Path(configuration_directory)  # no config.toml at all
            with mock.patch.object(release_gate.scratch_linear, "keychain_token_pair", return_value=None), \
                 mock.patch.object(release_gate.scratch_linear, "resolve_yh_path", return_value=Path("/usr/bin/true")):
                links = release_gate.resolve_night_card_links(
                    ["issue-1"], configuration_directory=configuration_directory, transport=FakeTransport(),
                )
        self.assertEqual(links["issue-1"], "issue-1")

    def test_empty_issue_ids_returns_empty_map(self):
        self.assertEqual(release_gate.resolve_night_card_links([]), {})


class WriteEvidenceTests(unittest.TestCase):
    def test_copies_snapshots_and_writes_night_cards_from_the_latest_snapshot_per_run(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work_directory = root / "work"
            evidence_directory = root / "evidence"
            write_journal_db(work_directory / "scenario-1" / "01-after-author.db", [("2026-08-01", None)])
            write_journal_db(
                work_directory / "scenario-1" / "02-after-land.db",
                [("2026-08-01", "issue-1"), ("2026-08-02", "issue-2")],
            )

            release_gate.write_evidence(
                work_directory, evidence_directory, configuration_directory=root / "no-config",
                transport=FakeTransport(),
            )

            self.assertTrue((evidence_directory / "journals" / "scenario-1" / "01-after-author.db").is_file())
            self.assertTrue((evidence_directory / "journals" / "scenario-1" / "02-after-land.db").is_file())

            night_cards = (evidence_directory / "night-cards.md").read_text()
            self.assertIn("scenario-1", night_cards)
            self.assertIn("issue-1", night_cards)
            self.assertIn("issue-2", night_cards)
            self.assertIn("2026-08-01", night_cards)
            self.assertIn("2026-08-02", night_cards)

    def test_no_snapshots_still_writes_an_empty_night_cards_file(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            work_directory = root / "work"
            work_directory.mkdir()
            evidence_directory = root / "evidence"

            release_gate.write_evidence(
                work_directory, evidence_directory, configuration_directory=root / "no-config",
                transport=FakeTransport(),
            )

            self.assertIn("No Night Cards", (evidence_directory / "night-cards.md").read_text())


class RecordCommandTests(unittest.TestCase):
    def _args(self, evidence_directory, scenario=None):
        return mock.Mock(
            app=Path("/Applications/Yellowhammer.app"), team="YLH",
            evidence_directory=evidence_directory, scenario=scenario, act_timeout=None,
        )

    def _run(self, evidence_directory, lines, returncode, dirty=False, commit="deadbeef", scenario=None):
        with mock.patch.object(release_gate, "git_commit_sha", return_value=commit), \
             mock.patch.object(release_gate, "git_tree_dirty", return_value=dirty), \
             mock.patch("subprocess.Popen", return_value=FakeProcess(lines, returncode)):
            return release_gate.record_command(self._args(evidence_directory, scenario=scenario))

    def test_all_scenarios_passing_clean_tree_yields_a_passing_verdict_and_zero_exit(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            lines = make_summary_lines(all_scenarios_summary())
            exit_code = self._run(evidence_directory, lines, returncode=0)
            self.assertEqual(exit_code, 0)
            verdict = json.loads((evidence_directory / "verdict.json").read_text())
            self.assertTrue(verdict["passed"])
            self.assertEqual(verdict["exit_code"], 0)
            self.assertFalse(verdict["dirty"])
            self.assertEqual(verdict["commit"], "deadbeef")
            self.assertEqual(len(verdict["scenario_results"]), release_gate.TOTAL_SCENARIOS)
            self.assertTrue((evidence_directory / "suite.log").is_file())

    def test_a_failed_scenario_yields_a_failing_verdict_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            lines = make_summary_lines(all_scenarios_summary(passed_numbers=set(release_gate.ALL_SCENARIOS) - {5}))
            exit_code = self._run(evidence_directory, lines, returncode=1)
            self.assertEqual(exit_code, 1)
            verdict = json.loads((evidence_directory / "verdict.json").read_text())
            self.assertFalse(verdict["passed"])
            failing = [r["number"] for r in verdict["scenario_results"] if not r["passed"]]
            self.assertEqual(failing, [5])

    def test_a_dirty_tree_fails_the_verdict_even_when_the_suite_passes(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            lines = make_summary_lines(all_scenarios_summary())
            exit_code = self._run(evidence_directory, lines, returncode=0, dirty=True)
            self.assertEqual(exit_code, 0)  # the suite's own exit code, unaffected by dirtiness
            verdict = json.loads((evidence_directory / "verdict.json").read_text())
            self.assertFalse(verdict["passed"])
            self.assertTrue(verdict["dirty"])

    def test_a_subset_run_fails_the_verdict_even_when_every_selected_scenario_passes(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            lines = make_summary_lines([(1, "Scenario 1", True)])
            exit_code = self._run(evidence_directory, lines, returncode=0, scenario=[1])
            self.assertEqual(exit_code, 0)
            verdict = json.loads((evidence_directory / "verdict.json").read_text())
            self.assertFalse(verdict["passed"])
            self.assertEqual(verdict["scenarios_selected"], [1])


class CheckCommandTests(unittest.TestCase):
    def _write_verdict(self, evidence_directory, **overrides):
        verdict = {
            "commit": "deadbeef",
            "dirty": False,
            "timestamp": "2026-09-25T00:00:00Z",
            "scenarios_selected": list(release_gate.ALL_SCENARIOS),
            "exit_code": 0,
            "scenario_results": all_scenarios_summary(),
            "passed": True,
        }
        verdict["scenario_results"] = [
            {"number": number, "title": title, "passed": passed}
            for number, title, passed in verdict["scenario_results"]
        ]
        verdict.update(overrides)
        evidence_directory.mkdir(parents=True, exist_ok=True)
        (evidence_directory / "verdict.json").write_text(json.dumps(verdict))

    def _args(self, evidence_directory, commit=None):
        return mock.Mock(evidence_directory=evidence_directory, commit=commit)

    def test_missing_verdict_fails(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            exit_code = release_gate.check_command(self._args(evidence_directory, commit="deadbeef"))
            self.assertEqual(exit_code, 1)

    def test_passing_verdict_at_the_matching_commit_passes(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            self._write_verdict(evidence_directory)
            exit_code = release_gate.check_command(self._args(evidence_directory, commit="deadbeef"))
            self.assertEqual(exit_code, 0)

    def test_verdict_reporting_passed_false_fails(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            self._write_verdict(evidence_directory, passed=False)
            exit_code = release_gate.check_command(self._args(evidence_directory, commit="deadbeef"))
            self.assertEqual(exit_code, 1)

    def test_a_failing_scenario_in_the_results_fails_even_if_passed_was_recorded_true(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            results = all_scenarios_summary(passed_numbers=set(release_gate.ALL_SCENARIOS) - {3})
            results = [{"number": n, "title": t, "passed": p} for n, t, p in results]
            self._write_verdict(evidence_directory, passed=True, scenario_results=results)
            exit_code = release_gate.check_command(self._args(evidence_directory, commit="deadbeef"))
            self.assertEqual(exit_code, 1)

    def test_a_subset_of_scenario_results_fails(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            self._write_verdict(evidence_directory, scenario_results=[{"number": 1, "title": "x", "passed": True}])
            exit_code = release_gate.check_command(self._args(evidence_directory, commit="deadbeef"))
            self.assertEqual(exit_code, 1)

    def test_a_commit_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            self._write_verdict(evidence_directory, commit="othersha")
            exit_code = release_gate.check_command(self._args(evidence_directory, commit="deadbeef"))
            self.assertEqual(exit_code, 1)

    def test_default_commit_reads_git_rev_parse_head(self):
        with tempfile.TemporaryDirectory() as evidence_directory:
            evidence_directory = Path(evidence_directory)
            self._write_verdict(evidence_directory, commit="deadbeef")
            with mock.patch.object(release_gate, "git_commit_sha", return_value="deadbeef"):
                exit_code = release_gate.check_command(self._args(evidence_directory, commit=None))
            self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
