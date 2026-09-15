#!/usr/bin/env python3
"""
Glossary conformance linter for Yellowhammer.

Scans Swift files and commit messages against rules defined in glossary_rules.json.
Outputs GitHub annotations and exits 0 unless tool crashes or JSON is invalid (exit 2).
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, Dict, List, Set, Tuple


@dataclass
class Finding:
    file: str
    line: int
    col: int
    rule_id: str
    message: str
    glossary: str


class GlossaryLinter:
    def __init__(self, rules_path: str, repo_root: str):
        self.repo_root = Path(repo_root)
        self.findings: List[Finding] = []

        try:
            with open(rules_path) as f:
                self.rules = json.load(f)
        except (json.JSONDecodeError, FileNotFoundError) as e:
            print(f"::error::Failed to load rules JSON: {e}", file=sys.stderr)
            sys.exit(2)

        # Compile regex patterns (skip GL007 which has kind marker)
        self.compiled_rules = []
        for rule in self.rules:
            if rule.get("kind") == "package-target-name":
                continue  # GL007 is handled separately
            try:
                flags = rule.get("flags", {})
                re_flags = 0 if flags.get("case_sensitive", True) else re.IGNORECASE
                pattern = re.compile(rule["pattern"], re_flags)
                self.compiled_rules.append((rule, pattern))
            except re.error as e:
                print(f"::error::Invalid regex in rule {rule['id']}: {e}", file=sys.stderr)
                sys.exit(2)

    def scan_files(self, paths: List[str]):
        """Scan files for glossary violations."""
        for path_str in paths:
            path = Path(path_str)
            if not path.exists():
                continue

            if path.is_file():
                self._scan_file(path)
            elif path.is_dir():
                for swift_file in path.rglob("*.swift"):
                    if ".build" not in swift_file.parts:
                        self._scan_file(swift_file)

    def _scan_file(self, file_path: Path):
        """Scan a single Swift file."""
        try:
            content = file_path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            return

        # Extract suppression comments
        suppressions = self._extract_suppressions(content)

        # Tokenize
        tokens = self._tokenize_swift(content)

        # Check each token
        for token_type, token_value, line_num, col_num in tokens:
            for rule, pattern in self.compiled_rules:
                if token_type not in rule.get("scopes", []):
                    continue

                # Check for suppression on this line
                if any(f"GL{rule['id'][2:]}" in supp for supp in suppressions.get(line_num, [])):
                    continue

                if pattern.search(token_value):
                    rel_path = str(file_path.relative_to(self.repo_root))
                    finding = Finding(
                        file=rel_path,
                        line=line_num,
                        col=col_num,
                        rule_id=rule["id"],
                        message=rule["message"],
                        glossary=rule["glossary"]
                    )
                    self.findings.append(finding)

    def _extract_suppressions(self, content: str) -> Dict[int, List[str]]:
        """Extract glossary:ignore comments and map to line numbers."""
        suppressions = {}
        for i, line in enumerate(content.split('\n'), 1):
            match = re.search(r"//\s*glossary:ignore\s+(GL\d+(?:\s+GL\d+)*)", line)
            if match:
                rule_ids = match.group(1).split()
                suppressions[i] = rule_ids
        return suppressions

    def _tokenize_swift(self, content: str) -> List[Tuple[str, str, int, int]]:
        """Tokenize Swift code into identifiers, strings, comments, etc."""
        tokens = []
        lines = content.split('\n')

        for line_num, line in enumerate(lines, 1):
            col = 0

            # Extract comments (everything after //)
            comment_match = re.search(r'//(.*)$', line)
            if comment_match:
                comment_text = comment_match.group(1)
                comment_col = comment_match.start()
                tokens.append(("comments", comment_text.strip(), line_num, comment_col))

            # Remove comments from line for further processing
            line_for_tokens = re.sub(r'//.*$', '', line)

            # Extract string literals (both single and triple-quoted)
            for string_match in re.finditer(r'"""[^"]*"""|"[^"]*"', line_for_tokens):
                string_val = string_match.group(0)
                # Remove quotes
                inner = string_val.strip('"')
                tokens.append(("strings", inner, line_num, string_match.start()))

            # Remove strings from line for identifier extraction
            line_for_ids = re.sub(r'"""[^"]*"""|"[^"]*"', '', line_for_tokens)

            # Extract identifiers (alphanumeric + underscores, CamelCase patterns)
            for id_match in re.finditer(r'\b[a-zA-Z_][a-zA-Z0-9_]*\b', line_for_ids):
                identifier = id_match.group(0)
                tokens.append(("identifiers", identifier, line_num, id_match.start()))

        return tokens

    def scan_commits(self, commit_range: str):
        """Scan commit messages in a range."""
        try:
            # Use git log to get commits in range
            result = subprocess.run(
                ["git", "-C", str(self.repo_root), "log", "--format=%H%x00%B%x1e", commit_range],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode != 0:
                return

            commits = result.stdout.split('\x1e')
            for commit_data in commits:
                if not commit_data.strip():
                    continue

                parts = commit_data.split('\x00', 1)
                if len(parts) != 2:
                    continue

                sha = parts[0][:7]
                message = parts[1]

                self._check_commit_message(sha, message)

        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass

    def _check_commit_message(self, sha: str, message: str):
        """Check a commit message against rules."""
        suppressions = self._extract_suppressions(message)
        lines = message.split('\n')

        for line_num, line in enumerate(lines, 1):
            for rule, pattern in self.compiled_rules:
                if "commit-messages" not in rule.get("scopes", []):
                    continue

                if any(f"GL{rule['id'][2:]}" in supp for supp in suppressions.get(line_num, [])):
                    continue

                if pattern.search(line):
                    finding = Finding(
                        file=f"(commit {sha})",
                        line=line_num,
                        col=0,
                        rule_id=rule["id"],
                        message=rule["message"],
                        glossary=rule["glossary"]
                    )
                    self.findings.append(finding)

    def extract_test_names(self, swift_file: Path) -> List[Tuple[str, int]]:
        """Extract test names from Swift test files."""
        test_names = []
        try:
            content = swift_file.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            return test_names

        # Match @Test("...") or func test... patterns
        for match in re.finditer(r'@Test\("([^"]+)"\)', content):
            test_names.append((match.group(1), content[:match.start()].count('\n') + 1))

        for match in re.finditer(r'func (test[a-zA-Z0-9_]*)\(', content):
            test_names.append((match.group(1), content[:match.start()].count('\n') + 1))

        return test_names

    def check_test_names(self, paths: List[str]):
        """Check test names for Port usage."""
        for path_str in paths:
            path = Path(path_str)
            if not path.exists():
                continue

            if path.is_file():
                if path.name.startswith("test") and path.suffix == ".swift":
                    self._check_test_file(path)
            elif path.is_dir():
                for test_file in path.rglob("test*.swift"):
                    if ".build" not in test_file.parts:
                        self._check_test_file(test_file)

    def _check_test_file(self, file_path: Path):
        """Check a test file for Port names in test names."""
        test_names = self.extract_test_names(file_path)
        suppressions = self._extract_suppressions(file_path.read_text(encoding="utf-8"))

        for test_name, line_num in test_names:
            for rule, pattern in self.compiled_rules:
                if rule["id"] != "GL003":  # Only GL003 applies to test-names
                    continue

                if line_num in suppressions:
                    continue

                if pattern.search(test_name):
                    rel_path = str(file_path.relative_to(self.repo_root))
                    finding = Finding(
                        file=rel_path,
                        line=line_num,
                        col=0,
                        rule_id=rule["id"],
                        message=rule["message"],
                        glossary=rule["glossary"]
                    )
                    self.findings.append(finding)

    def check_package_targets(self):
        """Check Package.swift for target names that match Port names."""
        package_file = self.repo_root / "Packages" / "YellowhammerKit" / "Package.swift"
        if not package_file.exists():
            return

        try:
            content = package_file.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            return

        # Find GL007 rule
        gl007_rule = None
        for rule in self.rules:
            if rule.get("id") == "GL007":
                gl007_rule = rule
                break

        if not gl007_rule:
            return

        port_names = {"Board", "Workspace", "Dispatch", "Publication"}

        # Pattern to match target definitions: .target(name: "...", or .executableTarget(name: "...", etc.
        for match in re.finditer(
            r'\.(?:test)?(?:executable)?[Tt]arget\s*\(\s*name\s*:\s*["\']([^"\']+)["\']',
            content
        ):
            target_name = match.group(1)
            if target_name in port_names:
                line_num = content[:match.start()].count('\n') + 1
                rel_path = str(package_file.relative_to(self.repo_root))
                finding = Finding(
                    file=rel_path,
                    line=line_num,
                    col=match.start() - content.rfind('\n', 0, match.start()) - 1,
                    rule_id="GL007",
                    message=gl007_rule["message"],
                    glossary=gl007_rule["glossary"]
                )
                self.findings.append(finding)

    def print_annotations(self):
        """Print GitHub annotations for findings."""
        for finding in sorted(self.findings, key=lambda f: (f.file, f.line)):
            print(f"::warning file={finding.file},line={finding.line},col={finding.col},title={finding.rule_id} glossary::{finding.message} (see {finding.glossary})")

    def print_summary(self):
        """Print summary count."""
        count = len(self.findings)
        if count == 0:
            print("No glossary violations found.")
        elif count == 1:
            print(f"1 glossary violation found.")
        else:
            print(f"{count} glossary violations found.")

    def write_summary_file(self, summary_file: str):
        """Write findings to a markdown table in the given file."""
        if not summary_file:
            return

        with open(summary_file, 'a') as f:
            f.write("\n## Glossary Conformance\n\n")

            if not self.findings:
                f.write("No findings.\n")
            else:
                f.write("| Rule | File | Line | Message |\n")
                f.write("|------|------|------|----------|\n")
                for finding in sorted(self.findings, key=lambda f: (f.file, f.line)):
                    f.write(f"| {finding.rule_id} | `{finding.file}` | {finding.line} | {finding.message} |\n")


def main():
    parser = argparse.ArgumentParser(description="Glossary conformance linter")
    parser.add_argument("--repo-root", required=True, help="Repository root")
    parser.add_argument("--rules", required=True, help="Rules JSON file path")
    parser.add_argument("--commits", help="Git commit range (e.g., HEAD~3..HEAD)")
    parser.add_argument("--paths", nargs="*", help="Paths to scan (default: Swift files under Packages/, Yellowhammer/, Engine/)")
    parser.add_argument("--summary-file", help="Write findings summary to this file")

    args = parser.parse_args()

    linter = GlossaryLinter(args.rules, args.repo_root)

    # Determine paths to scan
    if args.paths:
        paths = args.paths
    else:
        paths = [
            str(Path(args.repo_root) / "Packages"),
            str(Path(args.repo_root) / "Yellowhammer"),
            str(Path(args.repo_root) / "Engine"),
        ]

    # Scan files
    linter.scan_files(paths)

    # Scan test names
    linter.check_test_names(paths)

    # Check package targets (GL007)
    linter.check_package_targets()

    # Scan commits if specified
    if args.commits:
        linter.scan_commits(args.commits)

    # Output annotations
    linter.print_annotations()

    # Print summary
    linter.print_summary()

    # Write summary file if specified
    if args.summary_file:
        linter.write_summary_file(args.summary_file)

    # Always exit 0 unless internal error
    sys.exit(0)


if __name__ == "__main__":
    main()
