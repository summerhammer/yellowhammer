#!/usr/bin/env python3
"""
Unit tests for check_deployment_target.py
"""

import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


# Load the check_deployment_target module
script_path = Path(__file__).parent.parent / "check_deployment_target.py"
spec = importlib.util.spec_from_file_location("check_deployment_target", script_path)
check_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_module)


class TestNormalizeVersion(unittest.TestCase):
    """Tests for version normalization."""

    def test_simple_version(self):
        """Test simple X.Y version."""
        result = check_module.normalize_version("26.5")
        self.assertEqual(result, (26, 5, 0))

    def test_dot_v_format(self):
        """Test .vX format."""
        result = check_module.normalize_version(".v26")
        self.assertEqual(result, (26, 0, 0))

    def test_dot_v_underscore_format(self):
        """Test .vX_Y format."""
        result = check_module.normalize_version(".v26_5")
        self.assertEqual(result, (26, 5, 0))

    def test_quoted_version(self):
        """Test quoted version."""
        result = check_module.normalize_version('"26.5"')
        self.assertEqual(result, (26, 5, 0))

    def test_three_part_version(self):
        """Test three-part version."""
        result = check_module.normalize_version("26.5.1")
        self.assertEqual(result, (26, 5, 1))

    def test_versions_equal(self):
        """Test that equivalent versions are equal."""
        v1 = check_module.normalize_version("26.5")
        v2 = check_module.normalize_version(".v26_5")
        self.assertEqual(v1, v2)


class TestFormatVersion(unittest.TestCase):
    """Tests for version formatting."""

    def test_format_two_part(self):
        """Test formatting two-part version."""
        result = check_module.format_version((26, 5, 0))
        self.assertEqual(result, "26.5")

    def test_format_three_part(self):
        """Test formatting three-part version."""
        result = check_module.format_version((26, 5, 1))
        self.assertEqual(result, "26.5.1")


class TestCheckDeploymentTarget(unittest.TestCase):
    """Tests for deployment target checking."""

    def setUp(self):
        """Create temp directory for fixtures."""
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.temp_dir)

    def create_fixture_pbxproj(self, content):
        """Create a minimal pbxproj file."""
        pbxproj_dir = os.path.join(self.temp_dir, 'Yellowhammer.xcodeproj')
        os.makedirs(pbxproj_dir, exist_ok=True)
        pbxproj_file = os.path.join(pbxproj_dir, 'project.pbxproj')
        with open(pbxproj_file, 'w') as f:
            f.write(content)
        return pbxproj_file

    def create_fixture_package_swift(self, content):
        """Create a minimal Package.swift file."""
        pkg_dir = os.path.join(self.temp_dir, 'Packages', 'YellowhammerKit')
        os.makedirs(pkg_dir, exist_ok=True)
        pkg_file = os.path.join(pkg_dir, 'Package.swift')
        with open(pkg_file, 'w') as f:
            f.write(content)
        return pkg_file

    def test_equal_targets(self):
        """Test when all targets are equal."""
        pbxproj_content = """
        {
            MACOSX_DEPLOYMENT_TARGET = 26.5;
            MACOSX_DEPLOYMENT_TARGET = 26.5;
        }
        """
        package_content = """
        let package = Package(
            platforms: [
                .macOS("26.5")
            ]
        )
        """
        self.create_fixture_pbxproj(pbxproj_content)
        self.create_fixture_package_swift(package_content)

        # Test the component functions
        values, _ = check_module.check_pbxproj_targets(
            os.path.join(self.temp_dir, 'Yellowhammer.xcodeproj', 'project.pbxproj')
        )
        self.assertEqual(values, ['26.5', '26.5'])

    def test_package_differs(self):
        """Test when package version differs from pbxproj."""
        pbxproj_content = """
        MACOSX_DEPLOYMENT_TARGET = 26.5;
        """
        package_content = """
        let package = Package(
            platforms: [
                .macOS("26.0")
            ]
        )
        """
        self.create_fixture_pbxproj(pbxproj_content)
        self.create_fixture_package_swift(package_content)

        pbxproj_version, _ = check_module.check_pbxproj_targets(
            os.path.join(self.temp_dir, 'Yellowhammer.xcodeproj', 'project.pbxproj')
        )
        pkg_version, _, _ = check_module.check_package_swift_platform(
            os.path.join(self.temp_dir, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        pbxproj_norm = check_module.normalize_version(pbxproj_version[0])
        pkg_norm = check_module.normalize_version(pkg_version)
        self.assertNotEqual(pbxproj_norm, pkg_norm)

    def test_pbxproj_entries_differ(self):
        """Test when pbxproj entries differ."""
        pbxproj_content = """
        MACOSX_DEPLOYMENT_TARGET = 26.5;
        MACOSX_DEPLOYMENT_TARGET = 26.0;
        """
        package_content = """
        let package = Package(
            platforms: [
                .macOS("26.5")
            ]
        )
        """
        self.create_fixture_pbxproj(pbxproj_content)
        self.create_fixture_package_swift(package_content)

        values, _ = check_module.check_pbxproj_targets(
            os.path.join(self.temp_dir, 'Yellowhammer.xcodeproj', 'project.pbxproj')
        )
        normalized = [check_module.normalize_version(v) for v in values]
        self.assertGreater(len(set(normalized)), 1)

    def test_v26_vs_26_0(self):
        """Test that .v26 and 26.0 are equivalent."""
        v1 = check_module.normalize_version(".v26")
        v2 = check_module.normalize_version("26.0")
        self.assertEqual(v1, v2)

    def test_missing_pbxproj(self):
        """Test handling of missing pbxproj."""
        self.create_fixture_package_swift("""
        let package = Package(
            platforms: [.macOS("26.5")]
        )
        """)

        values, _ = check_module.check_pbxproj_targets(
            os.path.join(self.temp_dir, 'nonexistent.pbxproj')
        )
        self.assertIsNone(values)

    def test_missing_package_swift(self):
        """Test handling of missing Package.swift."""
        self.create_fixture_pbxproj("""
        MACOSX_DEPLOYMENT_TARGET = 26.5;
        """)

        version, line, path = check_module.check_package_swift_platform(
            os.path.join(self.temp_dir, 'nonexistent', 'Package.swift')
        )
        self.assertIsNone(version)

    def test_missing_platforms_key(self):
        """Test handling of missing platforms key."""
        self.create_fixture_package_swift("""
        let package = Package(
            name: "Test"
        )
        """)

        version, line, path = check_module.check_package_swift_platform(
            os.path.join(self.temp_dir, 'Packages', 'YellowhammerKit', 'Package.swift')
        )
        self.assertIsNone(version)


class TestRealRepo(unittest.TestCase):
    """Test against the real repository."""

    def test_real_repo_passes(self):
        """Test that the real repo passes the check."""
        # Find repo root by searching up from this file
        current_file = Path(__file__)
        repo_root = None

        for parent in current_file.parents:
            if (parent / 'Yellowhammer.xcodeproj').exists():
                repo_root = parent
                break

        if repo_root is None:
            self.skipTest("Could not locate real repository")

        # Check pbxproj
        pbxproj_values, pbxproj_lines = check_module.check_pbxproj_targets(
            str(repo_root / 'Yellowhammer.xcodeproj' / 'project.pbxproj')
        )
        self.assertIsNotNone(pbxproj_values, "pbxproj should have deployment targets")

        # Check all pbxproj values are equal
        normalized_pbxproj = [check_module.normalize_version(v) for v in pbxproj_values]
        self.assertEqual(
            len(set(normalized_pbxproj)),
            1,
            f"Multiple deployment target values: {pbxproj_values}"
        )

        # Check package.swift
        package_version, package_line, _ = check_module.check_package_swift_platform(
            str(repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift')
        )
        self.assertIsNotNone(package_version, "Package.swift should have macOS platform")

        # Compare
        pbxproj_norm = normalized_pbxproj[0]
        package_norm = check_module.normalize_version(package_version)
        self.assertEqual(
            pbxproj_norm,
            package_norm,
            f"pbxproj {pbxproj_values[0]} != Package.swift {package_version}"
        )


if __name__ == '__main__':
    unittest.main()
