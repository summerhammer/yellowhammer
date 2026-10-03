#!/usr/bin/env python3
"""
Unit tests for check_shell_not_host.py
"""

import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

# Load the check_shell_not_host module
script_path = Path(__file__).parent.parent / "check_shell_not_host.py"
spec = importlib.util.spec_from_file_location("check_shell_not_host", script_path)
check_shell_not_host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_shell_not_host)


class TestIsWindowApp(unittest.TestCase):
    """Tests for is_window_app function."""

    def test_window_app_basic(self):
        """True for basic Yellowhammer executable."""
        args = "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer"
        self.assertTrue(check_shell_not_host.is_window_app(args))

    def test_window_app_with_persistence_flag(self):
        """True for Yellowhammer with -ApplePersistenceIgnoreState flag."""
        args = "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer -ApplePersistenceIgnoreState YES"
        self.assertTrue(check_shell_not_host.is_window_app(args))

    def test_window_app_with_spaces_in_path(self):
        """True for Yellowhammer with spaces in path."""
        args = "/Applications/Yellow hammer/Yellowhammer.app/Contents/MacOS/Yellowhammer"
        self.assertTrue(check_shell_not_host.is_window_app(args))

    def test_not_window_app_post_notification(self):
        """False for Yellowhammer with --post-notification."""
        args = "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer --post-notification some-event"
        self.assertFalse(check_shell_not_host.is_window_app(args))

    def test_not_window_app_request_permission(self):
        """False for Yellowhammer with --request-notification-permission."""
        args = "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer --request-notification-permission"
        self.assertFalse(check_shell_not_host.is_window_app(args))

    def test_not_yh_engine(self):
        """False for yh engine rehearse process."""
        args = "/Applications/Yellowhammer.app/Contents/MacOS/yh rehearse --project alpha"
        self.assertFalse(check_shell_not_host.is_window_app(args))

    def test_not_unrelated_process(self):
        """False for unrelated process."""
        args = "/bin/bash -c 'echo hello'"
        self.assertFalse(check_shell_not_host.is_window_app(args))

    def test_not_unrelated_app(self):
        """False for different app."""
        args = "/Applications/OtherApp.app/Contents/MacOS/OtherApp"
        self.assertFalse(check_shell_not_host.is_window_app(args))


class TestRehearse_processes(unittest.TestCase):
    """Tests for rehearse_processes function."""

    def test_direct_yh_rehearse(self):
        """Picks direct /x/yh rehearse --project b."""
        processes = [
            check_shell_not_host.ProcessRow(100, 1, "/path/to/yh rehearse --project b"),
            check_shell_not_host.ProcessRow(101, 1, "/bin/sh -c '/path/to/yh rehearse --project b'"),
            check_shell_not_host.ProcessRow(102, 1, "python check_shell_not_host.py --project b"),
        ]
        result = check_shell_not_host.rehearse_processes(processes, "b")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].pid, 100)

    def test_stub_sh_wrapper(self):
        """Picks /bin/sh /w/stub-yh.sh rehearse --project b."""
        processes = [
            check_shell_not_host.ProcessRow(100, 1, "/bin/sh /work/stub-yh.sh rehearse --project b"),
            check_shell_not_host.ProcessRow(101, 1, "/bin/sh -c 'stub'"),
        ]
        result = check_shell_not_host.rehearse_processes(processes, "b")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].pid, 100)

    def test_excludes_sh_c_wrapper(self):
        """Excludes the /bin/sh -c ... wrapper."""
        processes = [
            check_shell_not_host.ProcessRow(100, 1, "/bin/sh -c 'yh rehearse --project b'"),
        ]
        result = check_shell_not_host.rehearse_processes(processes, "b")
        self.assertEqual(len(result), 0)

    def test_different_project_not_matched(self):
        """--project bb does not match --project b (endswith semantics)."""
        processes = [
            check_shell_not_host.ProcessRow(100, 1, "/path/to/yh rehearse --project bb"),
        ]
        result = check_shell_not_host.rehearse_processes(processes, "b")
        self.assertEqual(len(result), 0)

    def test_excludes_checker_process(self):
        """Excludes the checker's own process line."""
        processes = [
            check_shell_not_host.ProcessRow(100, 1, "python check_shell_not_host.py --project b"),
            check_shell_not_host.ProcessRow(101, 1, "/path/to/yh rehearse --project b"),
        ]
        result = check_shell_not_host.rehearse_processes(processes, "b")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].pid, 101)

    def test_exact_project_match(self):
        """Picks processes matching exact project id."""
        processes = [
            check_shell_not_host.ProcessRow(100, 1, "/path/to/yh rehearse --project alpha"),
            check_shell_not_host.ProcessRow(101, 1, "/path/to/yh rehearse --project bravo"),
        ]
        result = check_shell_not_host.rehearse_processes(processes, "alpha")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].pid, 100)


class TestNormaliser(unittest.TestCase):
    """Tests for Normaliser class."""

    def test_project_id_as_whole_token(self):
        """Project id replaced as whole token only."""
        project = check_shell_not_host.ProjectFacts(
            id="alpha", name="Alpha Project", linear_project="LIN-123", paths=()
        )
        normaliser = check_shell_not_host.Normaliser(project)

        # Should replace in "alpha" and alpha/x
        self.assertIn("<project>", normaliser.text('"alpha"'))
        self.assertIn("<project>", normaliser.text("alpha/x"))

        # Should not replace inside alphabet or alpha-2
        self.assertNotIn("<project>", normaliser.text("alphabet"))
        self.assertNotIn("<project>", normaliser.text("alpha-2"))

    def test_project_name_replaced(self):
        """Project name replaced by label."""
        project = check_shell_not_host.ProjectFacts(
            id="id1", name="My Project Name", linear_project="", paths=()
        )
        normaliser = check_shell_not_host.Normaliser(project)
        result = normaliser.text("My Project Name is cool")
        self.assertIn("<project name>", result)

    def test_linear_project_replaced(self):
        """Linear project replaced by label."""
        project = check_shell_not_host.ProjectFacts(
            id="id1", name="", linear_project="LINEAR-PROJ", paths=()
        )
        normaliser = check_shell_not_host.Normaliser(project)
        result = normaliser.text("LINEAR-PROJ is the board")
        self.assertIn("<linear project>", result)

    def test_repo_paths_replaced(self):
        """Repo paths replaced by labels."""
        project = check_shell_not_host.ProjectFacts(
            id="id1", name="", linear_project="",
            paths=(("/home/user/repo", "<repo backend>"), ("/home/user/spec", "<spec source>"))
        )
        normaliser = check_shell_not_host.Normaliser(project)
        result = normaliser.text("/home/user/repo/file.txt and /home/user/spec/doc.md")
        self.assertIn("<repo backend>", result)
        self.assertIn("<spec source>", result)

    def test_iso_timestamp_normalized(self):
        """ISO timestamps with Z, offset, and fractional seconds → <time>."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        self.assertIn("<time>", normaliser.text("2026-09-24T10:30:45Z"))
        self.assertIn("<time>", normaliser.text("2026-09-24T10:30:45+00:00"))
        self.assertIn("<time>", normaliser.text("2026-09-24T10:30:45.123456Z"))
        self.assertIn("<time>", normaliser.text("2026-09-24 10:30:45"))

    def test_uuid_aliasing(self):
        """UUIDs aliased <uuid-1>, <uuid-2> in first-appearance order."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        uuid1 = "550e8400-e29b-41d4-a716-446655440000"
        uuid2 = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

        result = normaliser.text(f"First: {uuid1}, Second: {uuid2}, First again: {uuid1}")
        # Both UUIDs should be normalized
        self.assertIn("<uuid-1>", result)
        self.assertIn("<uuid-2>", result)
        # Same UUID should map to same alias
        self.assertEqual(result.count("<uuid-1>"), 2)

    def test_uuid_case_insensitive(self):
        """Same UUID in different cases maps to same alias."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        uuid_lower = "550e8400-e29b-41d4-a716-446655440000"
        uuid_upper = "550E8400-E29B-41D4-A716-446655440000"

        result = normaliser.text(f"{uuid_lower} and {uuid_upper}")
        # Should use same alias for both
        self.assertEqual(result.count("<uuid-1>"), 2)

    def test_issue_key_aliasing(self):
        """Issue keys like YHS-12 → <key-N>."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        result = normaliser.text("YHS-12 and ABC-1 and YHS-12 again")
        self.assertIn("<key-1>", result)
        self.assertIn("<key-2>", result)
        self.assertEqual(result.count("<key-1>"), 2)

    def test_git_sha_aliasing(self):
        """40-hex SHAs → <sha-N>."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        sha1 = "0123456789abcdef0123456789abcdef01234567"
        sha2 = "fedcba9876543210fedcba9876543210fedcba98"

        result = normaliser.text(f"SHA1: {sha1}, SHA2: {sha2}")
        self.assertIn("<sha-1>", result)
        self.assertIn("<sha-2>", result)

    def test_url_aliasing(self):
        """URLs → <url-N>."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        result = normaliser.text("https://example.com and http://other.org/path")
        self.assertIn("<url-1>", result)
        self.assertIn("<url-2>", result)

    def test_non_string_passes_through(self):
        """Non-strings pass through unchanged."""
        project = check_shell_not_host.ProjectFacts(id="id1", name="", linear_project="", paths=())
        normaliser = check_shell_not_host.Normaliser(project)

        self.assertEqual(normaliser.value(42), 42)
        self.assertEqual(normaliser.value(None), None)
        self.assertEqual(normaliser.value(True), True)


class TestCompare(unittest.TestCase):
    """Tests for compare function."""

    def test_equal_lists_return_empty(self):
        """Equal lists return empty list."""
        first = ["line1", "line2", "line3"]
        second = ["line1", "line2", "line3"]
        result = check_shell_not_host.compare("first", first, "second", second)
        self.assertEqual(result, [])

    def test_different_lists_return_diff(self):
        """Different lists return non-empty unified diff."""
        first = ["line1", "line2", "line3"]
        second = ["line1", "line2_modified", "line3"]
        result = check_shell_not_host.compare("first", first, "second", second)
        self.assertNotEqual(result, [])
        self.assertTrue(any("---" in line or "+++" in line or "@@" in line or "-line2" in line for line in result))

    def test_empty_lists(self):
        """Empty lists are equal."""
        result = check_shell_not_host.compare("a", [], "b", [])
        self.assertEqual(result, [])

    def test_one_empty_one_full(self):
        """One empty, one full returns diff."""
        first = []
        second = ["line1", "line2"]
        result = check_shell_not_host.compare("first", first, "second", second)
        self.assertNotEqual(result, [])


class TestSnapshot(unittest.TestCase):
    """Tests for snapshot function."""

    def test_snapshot_copies_db(self):
        """Snapshot copies the database file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create a test database
            original_db = tmppath / "original.db"
            conn = sqlite3.connect(original_db)
            conn.execute("CREATE TABLE test (id INTEGER, name TEXT)")
            conn.execute("INSERT INTO test VALUES (1, 'hello')")
            conn.commit()
            conn.close()

            # Create snapshot
            snapshot_dir = tmppath / "snapshots"
            copy = check_shell_not_host.snapshot(original_db, snapshot_dir)

            # Verify copy exists and is readable
            self.assertTrue(copy.exists())
            conn = sqlite3.connect(copy)
            result = conn.execute("SELECT * FROM test").fetchall()
            self.assertEqual(result, [(1, 'hello')])
            conn.close()

    def test_snapshot_copies_wal(self):
        """Snapshot copies WAL file if present."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create a test database in WAL mode
            original_db = tmppath / "original.db"
            conn = sqlite3.connect(original_db)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("CREATE TABLE test (id INTEGER)")
            conn.execute("INSERT INTO test VALUES (1)")
            conn.commit()
            conn.close()

            # Force WAL file creation
            wal_file = original_db.with_name(original_db.name + "-wal")

            # Create snapshot
            snapshot_dir = tmppath / "snapshots"
            copy = check_shell_not_host.snapshot(original_db, snapshot_dir)

            # Verify copy exists
            self.assertTrue(copy.exists())
            if wal_file.exists():
                copy_wal = copy.with_name(copy.name + "-wal")
                self.assertTrue(copy_wal.exists())


class TestLoadProject(unittest.TestCase):
    """Tests for load_project function."""

    def test_load_project_success(self):
        """Load a valid project TOML."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)
            projects_dir = tmppath / "projects"
            projects_dir.mkdir()

            # Create a project TOML
            project_file = projects_dir / "alpha.toml"
            project_file.write_text("""
id = "alpha"
name = "Alpha Project"
spec_source = "~/repos/spec"

[board.linear]
installation = "scratch"
project = "LINEAR-ALPHA"

[[repos]]
name = "backend"
path = "~/repos/backend"

[[repos]]
name = "frontend"
path = "~/repos/frontend"
""")

            result = check_shell_not_host.load_project(tmppath, "alpha")

            self.assertEqual(result.id, "alpha")
            self.assertEqual(result.name, "Alpha Project")
            self.assertEqual(result.linear_project, "LINEAR-ALPHA")
            # Should include both ~ and expanded forms
            paths_str = str(result.paths)
            self.assertIn("~/repos", paths_str)
            self.assertIn("/repos", paths_str)

    def test_load_project_not_found(self):
        """Raise SetupFailed for unknown project id."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)
            projects_dir = tmppath / "projects"
            projects_dir.mkdir()

            with self.assertRaises(check_shell_not_host.SetupFailed):
                check_shell_not_host.load_project(tmppath, "nonexistent")

    def test_load_project_with_expanded_paths(self):
        """Loaded project includes both ~ and expanded home paths."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)
            projects_dir = tmppath / "projects"
            projects_dir.mkdir()

            project_file = projects_dir / "proj.toml"
            project_file.write_text("""
id = "proj"
spec_source = "~/spec"
""")

            result = check_shell_not_host.load_project(tmppath, "proj")

            # Should have both forms
            paths_dict = {path: label for path, label in result.paths}
            self.assertIn("~/spec", paths_dict)
            expanded = os.path.expanduser("~/spec")
            self.assertIn(expanded, paths_dict)


class TestEndToEndFixtures(unittest.TestCase):
    """End-to-end tests with fixture databases."""

    def _create_fixture_journal(self, path, project_id, night_card_issue_id="LIN-100", add_events=False):
        """Create a fixture Journal database."""
        conn = sqlite3.connect(path)

        # Create grdb_migrations table (ignored)
        conn.execute("CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY)")
        conn.execute("INSERT INTO grdb_migrations VALUES ('001')")

        # Create night table with night_card_issue_id
        conn.execute("""
            CREATE TABLE night (
                id INTEGER PRIMARY KEY,
                night_card_issue_id TEXT,
                created_at TEXT
            )
        """)
        conn.execute(
            "INSERT INTO night VALUES (1, ?, '2026-09-24T10:00:00Z')",
            (night_card_issue_id,)
        )

        # Create outbox table
        conn.execute("""
            CREATE TABLE outbox (
                id INTEGER PRIMARY KEY,
                issue_id TEXT,
                event TEXT,
                created_at TEXT
            )
        """)
        if add_events:
            conn.execute(
                "INSERT INTO outbox VALUES (1, ?, 'event1', '2026-09-24T10:01:00Z')",
                (night_card_issue_id,)
            )
            conn.execute(
                "INSERT INTO outbox VALUES (2, ?, 'event2', '2026-09-24T10:02:00Z')",
                (night_card_issue_id,)
            )

        # Create other tables for completeness
        conn.execute("""
            CREATE TABLE act_lease (
                id INTEGER PRIMARY KEY,
                act TEXT
            )
        """)

        conn.commit()
        conn.close()

    def test_normalised_same_shape_same_result(self):
        """Two DBs with same shape but different IDs normalize to equivalent output."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create two journals
            db1 = tmppath / "alpha.db"
            db2 = tmppath / "bravo.db"
            self._create_fixture_journal(db1, "alpha", "LIN-100")
            self._create_fixture_journal(db2, "bravo", "LIN-200")

            # Create projects
            project_alpha = check_shell_not_host.ProjectFacts(
                id="alpha", name="Alpha", linear_project="LIN-ALPHA", paths=()
            )
            project_bravo = check_shell_not_host.ProjectFacts(
                id="bravo", name="Bravo", linear_project="LIN-BRAVO", paths=()
            )

            # Normalise both
            cards1, journal1 = check_shell_not_host.normalised(db1, project_alpha)
            cards2, journal2 = check_shell_not_host.normalised(db2, project_bravo)

            # Should have same shape
            self.assertEqual(len(cards1), len(cards2))
            self.assertEqual(len(journal1), len(journal2))

    def test_normalised_extra_event_shows_difference(self):
        """Extra event row in bravo results in different normalized output."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            db1 = tmppath / "alpha.db"
            db2 = tmppath / "bravo.db"
            self._create_fixture_journal(db1, "alpha", "LIN-100", add_events=False)
            self._create_fixture_journal(db2, "bravo", "LIN-200", add_events=True)

            project1 = check_shell_not_host.ProjectFacts(
                id="alpha", name="Alpha", linear_project="", paths=()
            )
            project2 = check_shell_not_host.ProjectFacts(
                id="bravo", name="Bravo", linear_project="", paths=()
            )

            cards1, journal1 = check_shell_not_host.normalised(db1, project1)
            cards2, journal2 = check_shell_not_host.normalised(db2, project2)

            # Should have different line counts (bravo has more outbox rows)
            full1 = cards1 + [""] + journal1
            full2 = cards2 + [""] + journal2
            diff = check_shell_not_host.compare("a", full1, "b", full2)
            self.assertNotEqual(diff, [])

    def test_night_cards_only_includes_matching_issue_ids(self):
        """night_cards only includes outbox rows whose issue_id is a night_card_issue_id."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)
            db = tmppath / "test.db"

            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE night (id INTEGER, night_card_issue_id TEXT)")
            conn.execute("INSERT INTO night VALUES (1, 'LIN-100')")
            conn.execute("CREATE TABLE outbox (id INTEGER, issue_id TEXT, event TEXT)")
            conn.execute("INSERT INTO outbox VALUES (1, 'LIN-100', 'event1')")
            conn.execute("INSERT INTO outbox VALUES (2, 'LIN-999', 'event2')")  # Different issue
            conn.commit()
            conn.close()

            project = check_shell_not_host.ProjectFacts(id="test", name="", linear_project="", paths=())
            normaliser = check_shell_not_host.Normaliser(project)

            conn = sqlite3.connect(db)
            cards = check_shell_not_host.night_cards(conn, normaliser)
            conn.close()

            # Should have 1 night line + 1 matching outbox line
            self.assertEqual(len(cards), 2)
            # Should have LIN-100 (normalized to <key-1>) but not LIN-999
            combined = " ".join(cards)
            self.assertIn("<key-1>", combined)
            self.assertNotIn("<key-2>", combined)


class TestBuildHarness(unittest.TestCase):
    """Tests for build_harness function."""

    def test_same_project_raises_setup_failed(self):
        """Same project for both Nights raises SetupFailed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create fake app
            app = tmppath / "Yellowhammer.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            (app / "yh").touch()
            (app / "Yellowhammer").touch()

            args = check_shell_not_host.parse_arguments([
                "--app", str(tmppath / "Yellowhammer.app"),
                "--never-opened", "alpha",
                "--quit-mid-act", "alpha",
            ])

            with self.assertRaises(check_shell_not_host.SetupFailed):
                check_shell_not_host.build_harness(args)

    def test_custom_config_dir_without_stub_raises_setup_failed(self):
        """--configuration-directory without --engine-stub raises SetupFailed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create fake app
            app = tmppath / "Yellowhammer.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            (app / "yh").touch()
            (app / "Yellowhammer").touch()

            args = check_shell_not_host.parse_arguments([
                "--app", str(tmppath / "Yellowhammer.app"),
                "--never-opened", "alpha",
                "--quit-mid-act", "bravo",
                "--configuration-directory", "/tmp/custom",
            ])

            with self.assertRaises(check_shell_not_host.SetupFailed):
                check_shell_not_host.build_harness(args)

    def test_app_without_yh_raises_setup_failed(self):
        """App directory without Contents/MacOS/yh raises SetupFailed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create app without yh
            app = tmppath / "Yellowhammer.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            (app / "Yellowhammer").touch()  # Yellowhammer but not yh

            args = check_shell_not_host.parse_arguments([
                "--app", str(tmppath / "Yellowhammer.app"),
                "--never-opened", "alpha",
                "--quit-mid-act", "bravo",
            ])

            with self.assertRaises(check_shell_not_host.SetupFailed):
                check_shell_not_host.build_harness(args)

    def test_existing_journal_raises_setup_failed(self):
        """Existing journal for either project raises SetupFailed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create fake app
            app = tmppath / "Yellowhammer.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            (app / "yh").touch()
            (app / "Yellowhammer").touch()

            # Create config dir with a project and journal
            config_dir = tmppath / "config"
            config_dir.mkdir()
            projects_dir = config_dir / "projects"
            projects_dir.mkdir()
            journals_dir = config_dir / "journals"
            journals_dir.mkdir()

            # Create a project file
            (projects_dir / "alpha.toml").write_text('id = "alpha"')

            # Create an existing journal
            (journals_dir / "alpha.db").touch()

            args = check_shell_not_host.parse_arguments([
                "--app", str(tmppath / "Yellowhammer.app"),
                "--never-opened", "alpha",
                "--quit-mid-act", "bravo",
                "--configuration-directory", str(config_dir),
                "--engine-stub", str(tmppath / "stub.sh"),
            ])

            with self.assertRaises(check_shell_not_host.SetupFailed):
                check_shell_not_host.build_harness(args)

    def test_app_running_raises_setup_failed(self):
        """Running app raises SetupFailed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create fake app
            app = tmppath / "Yellowhammer.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            (app / "yh").touch()
            (app / "Yellowhammer").touch()

            args = check_shell_not_host.parse_arguments([
                "--app", str(tmppath / "Yellowhammer.app"),
                "--never-opened", "alpha",
                "--quit-mid-act", "bravo",
            ])

            # Mock list_processes to return a running app
            mock_process = check_shell_not_host.ProcessRow(
                100, 1, "/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer"
            )
            with patch.object(check_shell_not_host, 'list_processes', return_value=[mock_process]):
                with self.assertRaises(check_shell_not_host.SetupFailed):
                    check_shell_not_host.build_harness(args)

    def test_valid_build_harness(self):
        """Valid arguments produce a Harness."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create fake app
            app = tmppath / "Yellowhammer.app" / "Contents" / "MacOS"
            app.mkdir(parents=True)
            (app / "yh").touch()
            (app / "Yellowhammer").touch()

            # Mock list_processes to return no app
            with patch.object(check_shell_not_host, 'list_processes', return_value=[]):
                args = check_shell_not_host.parse_arguments([
                    "--app", str(tmppath / "Yellowhammer.app"),
                    "--never-opened", "alpha",
                    "--quit-mid-act", "bravo",
                ])

                harness = check_shell_not_host.build_harness(args)

                self.assertIsNotNone(harness)
                # Compare resolved paths since build_harness resolves the app path
                self.assertEqual(harness.app, (tmppath / "Yellowhammer.app").resolve())


class TestParseArguments(unittest.TestCase):
    """Tests for parse_arguments function."""

    def test_required_arguments(self):
        """Parse required arguments."""
        args = check_shell_not_host.parse_arguments([
            "--app", "/path/to/app",
            "--never-opened", "alpha",
            "--quit-mid-act", "bravo",
        ])

        self.assertEqual(args.app, Path("/path/to/app"))
        self.assertEqual(args.never_opened, "alpha")
        self.assertEqual(args.quit_mid_act, "bravo")

    def test_optional_arguments(self):
        """Parse optional arguments."""
        args = check_shell_not_host.parse_arguments([
            "--app", "/path/to/app",
            "--never-opened", "alpha",
            "--quit-mid-act", "bravo",
            "--timeout", "3600",
            "--engine-stub", "/path/to/stub",
        ])

        self.assertEqual(args.timeout, 3600.0)
        self.assertEqual(args.engine_stub, Path("/path/to/stub"))


if __name__ == "__main__":
    unittest.main()
