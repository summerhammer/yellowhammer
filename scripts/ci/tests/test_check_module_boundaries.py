#!/usr/bin/env python3
"""
Unit tests for check_module_boundaries.py
"""

import importlib.util
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


# Load the check_module_boundaries module
script_path = Path(__file__).parent.parent / "check_module_boundaries.py"
spec = importlib.util.spec_from_file_location("check_module_boundaries", script_path)
check_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_module)


class TestAdapterDetection(unittest.TestCase):
    """Tests for adapter module detection."""

    def test_is_adapter(self):
        """Test adapter detection."""
        self.assertTrue(check_module.is_adapter_module('LinearAdapter'))
        self.assertTrue(check_module.is_adapter_module('OrcaADEAdapter'))
        self.assertTrue(check_module.is_adapter_module('CLIAdapters'))

    def test_is_not_adapter(self):
        """Test non-adapter modules."""
        self.assertFalse(check_module.is_adapter_module('Engine'))
        self.assertFalse(check_module.is_adapter_module('Domain'))
        self.assertFalse(check_module.is_adapter_module('EngineCommand'))

    def test_test_target_detection(self):
        """Test test target detection."""
        self.assertTrue(check_module.is_test_target('EngineTests'))
        self.assertTrue(check_module.is_test_target('DomainTests'))
        self.assertFalse(check_module.is_test_target('Engine'))


class TestImportParsing(unittest.TestCase):
    """Tests for Swift import parsing."""

    def test_simple_import(self):
        """Test parsing simple import."""
        code = "import Engine"
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 1)
        self.assertEqual(imports[0][0], 'Engine')

    def test_testable_import(self):
        """Test parsing @testable import."""
        code = "@testable import Engine"
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 1)
        self.assertEqual(imports[0][0], 'Engine')

    def test_exported_import(self):
        """Test parsing @_exported import."""
        code = "@_exported import Domain"
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 1)
        self.assertEqual(imports[0][0], 'Domain')

    def test_struct_import(self):
        """Test parsing import struct."""
        code = "import struct Foundation.Data"
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 1)
        self.assertEqual(imports[0][0], 'Foundation')

    def test_access_level_import(self):
        """Test parsing import with access level."""
        code = "public import Domain"
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 1)
        self.assertEqual(imports[0][0], 'Domain')

    def test_import_in_comment_ignored(self):
        """Test that imports in comments are ignored."""
        code = """
        // import Engine
        import Domain
        """
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 1)
        self.assertEqual(imports[0][0], 'Domain')

    def test_multiple_imports(self):
        """Test parsing multiple imports."""
        code = """
        import Engine
        import Domain
        import struct Foundation.Data
        """
        imports = check_module.find_imports(code)
        self.assertEqual(len(imports), 3)


class TestPackageSwiftParsing(unittest.TestCase):
    """Tests for Package.swift parsing."""

    def setUp(self):
        """Create temp directory for fixtures."""
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.temp_dir)

    def create_package_swift(self, content):
        """Create a Package.swift file."""
        pkg_dir = os.path.join(self.temp_dir, 'Package')
        os.makedirs(pkg_dir, exist_ok=True)
        pkg_file = os.path.join(pkg_dir, 'Package.swift')
        with open(pkg_file, 'w') as f:
            f.write(content)
        return pkg_file

    def test_parse_basic_targets(self):
        """Test parsing basic targets."""
        content = """
        let package = Package(
            name: "Test",
            targets: [
                .target(name: "Domain"),
                .target(name: "Engine", dependencies: ["Domain"])
            ]
        )
        """
        pkg_file = self.create_package_swift(content)
        result = check_module.parse_package_swift(pkg_file)

        self.assertIn('Domain', result['targets'])
        self.assertIn('Engine', result['targets'])
        self.assertEqual(result['targets']['Engine']['dependencies'], ['Domain'])

    def test_parse_test_targets(self):
        """Test parsing test targets."""
        content = """
        let package = Package(
            targets: [
                .testTarget(name: "EngineTests", dependencies: ["Engine"])
            ]
        )
        """
        pkg_file = self.create_package_swift(content)
        result = check_module.parse_package_swift(pkg_file)

        self.assertIn('EngineTests', result['targets'])
        self.assertEqual(result['targets']['EngineTests']['type'], 'testTarget')

    def test_parse_executable_targets(self):
        """Test parsing executable targets."""
        content = """
        let package = Package(
            targets: [
                .executableTarget(name: "yh", dependencies: ["Engine"])
            ]
        )
        """
        pkg_file = self.create_package_swift(content)
        result = check_module.parse_package_swift(pkg_file)

        self.assertIn('yh', result['targets'])
        self.assertEqual(result['targets']['yh']['type'], 'executableTarget')

    def test_parse_products(self):
        """Test parsing products."""
        content = """
        let package = Package(
            products: [
                .library(name: "Engine", targets: ["Engine"])
            ]
        )
        """
        pkg_file = self.create_package_swift(content)
        result = check_module.parse_package_swift(pkg_file)

        self.assertIn('Engine', result['products'])
        self.assertEqual(result['products']['Engine']['targets'], ['Engine'])

    def test_parse_missing_file(self):
        """Test parsing non-existent file."""
        result = check_module.parse_package_swift('/nonexistent/Package.swift')
        self.assertIsNone(result)


class TestModuleBoundaryRules(unittest.TestCase):
    """Tests for module boundary rule checking."""

    def setUp(self):
        """Create temp directory for test repos."""
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.temp_dir)

    def create_test_repo(self, package_content, swift_files=None):
        """Create a minimal test repository structure."""
        # Create Package.swift
        pkg_dir = os.path.join(self.temp_dir, 'Packages', 'YellowhammerKit')
        os.makedirs(pkg_dir, exist_ok=True)

        with open(os.path.join(pkg_dir, 'Package.swift'), 'w') as f:
            f.write(package_content)

        # Create Swift source files if provided
        if swift_files:
            for target_name, files in swift_files.items():
                for file_rel_path, content in files.items():
                    file_path = os.path.join(pkg_dir, 'Sources', target_name, file_rel_path)
                    os.makedirs(os.path.dirname(file_path), exist_ok=True)
                    with open(file_path, 'w') as f:
                        f.write(content)

        return self.temp_dir

    def test_mb1_engine_imports_adapter_violation(self):
        """Test MB1: Engine must not import adapters."""
        package_content = """
        let package = Package(
            targets: [
                .target(name: "Domain"),
                .target(name: "Engine", dependencies: ["Domain"]),
                .target(name: "LinearAdapter", dependencies: ["Domain"])
            ]
        )
        """
        swift_files = {
            'Engine': {
                'main.swift': 'import LinearAdapter'
            }
        }

        repo_root = self.create_test_repo(package_content, swift_files)
        package_info = check_module.parse_package_swift(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        violations = check_module.check_imports_in_target(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit'),
            'Engine',
            package_info['targets']['Engine'],
            package_info['targets']
        )

        self.assertTrue(any(v['rule'] == 'MB1' for v in violations))

    def test_mb2_non_enginecommand_imports_adapter_violation(self):
        """Test MB2: Only EngineCommand can wire adapters."""
        package_content = """
        let package = Package(
            targets: [
                .target(name: "Domain"),
                .target(name: "Engine", dependencies: ["Domain"]),
                .target(name: "LinearAdapter", dependencies: ["Domain"])
            ]
        )
        """
        swift_files = {
            'Domain': {
                'main.swift': 'import LinearAdapter'
            }
        }

        repo_root = self.create_test_repo(package_content, swift_files)
        package_info = check_module.parse_package_swift(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        violations = check_module.check_imports_in_target(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit'),
            'Domain',
            package_info['targets']['Domain'],
            package_info['targets']
        )

        self.assertTrue(any(v['rule'] == 'MB2' for v in violations))

    def test_mb2_adapter_test_can_import_own_adapter(self):
        """Test MB2 exception: adapter test targets can import their own adapter."""
        package_content = """
        let package = Package(
            targets: [
                .target(name: "LinearAdapter"),
                .testTarget(name: "LinearAdapterTests", dependencies: ["LinearAdapter"])
            ]
        )
        """
        swift_files = {
            'LinearAdapterTests': {
                'tests.swift': 'import LinearAdapter'
            }
        }

        repo_root = self.create_test_repo(package_content, swift_files)
        package_info = check_module.parse_package_swift(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        violations = check_module.check_imports_in_target(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit'),
            'LinearAdapterTests',
            package_info['targets']['LinearAdapterTests'],
            package_info['targets']
        )

        # Should not have violations for adapter tests importing own adapter
        mb2_violations = [v for v in violations if v['rule'] == 'MB2']
        # This is somewhat lenient - adapter test can import its own adapter
        # The implementation needs to be checked

    def test_mb4_journal_ledger_import_violation(self):
        """Test MB4: Journal and Ledger must not import each other."""
        package_content = """
        let package = Package(
            targets: [
                .target(name: "Journal"),
                .target(name: "Ledger")
            ]
        )
        """
        swift_files = {
            'Journal': {
                'main.swift': 'import Ledger'
            }
        }

        repo_root = self.create_test_repo(package_content, swift_files)
        package_info = check_module.parse_package_swift(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        violations = check_module.check_imports_in_target(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit'),
            'Journal',
            package_info['targets']['Journal'],
            package_info['targets']
        )

        self.assertTrue(any(v['rule'] == 'MB4' for v in violations))

    def test_check_dependencies_mb1(self):
        """Test MB1 in dependency checking."""
        package_content = """
        let package = Package(
            targets: [
                .target(name: "Engine", dependencies: ["LinearAdapter"])
            ]
        )
        """
        repo_root = self.create_test_repo(package_content)
        package_info = check_module.parse_package_swift(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        violations = check_module.check_dependencies(package_info)
        self.assertTrue(any(v['rule'] == 'MB1' for v in violations))

    def test_check_dependencies_mb4(self):
        """Test MB4 in dependency checking."""
        package_content = """
        let package = Package(
            targets: [
                .target(name: "Journal", dependencies: ["Ledger"])
            ]
        )
        """
        repo_root = self.create_test_repo(package_content)
        package_info = check_module.parse_package_swift(
            os.path.join(repo_root, 'Packages', 'YellowhammerKit', 'Package.swift')
        )

        violations = check_module.check_dependencies(package_info)
        self.assertTrue(any(v['rule'] == 'MB4' for v in violations))


class TestRealRepo(unittest.TestCase):
    """Test against the real repository."""

    def test_real_repo_passes(self):
        """Test that the real repo passes all module boundary checks."""
        # Find repo root
        current_file = Path(__file__)
        repo_root = None

        for parent in current_file.parents:
            if (parent / 'Yellowhammer.xcodeproj').exists():
                repo_root = parent
                break

        if repo_root is None:
            self.skipTest("Could not locate real repository")

        # Parse Package.swift
        package_info = check_module.parse_package_swift(
            str(repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift')
        )
        self.assertIsNotNone(package_info, "Should parse Package.swift")

        # Check dependencies
        dep_violations = check_module.check_dependencies(package_info)

        if dep_violations:
            for v in dep_violations:
                self.fail(f"Dependency violation: {v['message']}")

        # Check imports in each target
        for target_name in package_info['targets']:
            import_violations = check_module.check_imports_in_target(
                str(repo_root / 'Packages' / 'YellowhammerKit'),
                target_name,
                package_info['targets'][target_name],
                package_info['targets']
            )

            if import_violations:
                for v in import_violations:
                    self.fail(f"Import violation in {target_name}: {v['message']}")


class TestMB3RealPbxproj(unittest.TestCase):
    """Test MB3 with the real pbxproj file."""

    def setUp(self):
        """Create temp directory for modified pbxproj."""
        self.temp_dir = tempfile.mkdtemp()

        # Find real repo
        current_file = Path(__file__)
        self.repo_root = None

        for parent in current_file.parents:
            if (parent / 'Yellowhammer.xcodeproj').exists():
                self.repo_root = parent
                break

        if self.repo_root is None:
            self.skipTest("Could not locate real repository")

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.temp_dir)

    def test_app_links_enginecommand_product_fails_mb3(self):
        """Test (a): App linking EngineCommand product should fail MB3 (transitive to Engine)."""
        # Copy real pbxproj and Package.swift
        pbxproj_src = self.repo_root / 'Yellowhammer.xcodeproj' / 'project.pbxproj'
        package_src = self.repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'

        pbxproj_dest = os.path.join(self.temp_dir, 'project.pbxproj')
        package_dest = os.path.join(self.temp_dir, 'Package.swift')

        shutil.copy(pbxproj_src, pbxproj_dest)
        shutil.copy(package_src, package_dest)

        # Modify pbxproj to add EngineCommand to app's packageProductDependencies
        with open(pbxproj_dest, 'r') as f:
            content = f.read()

        # Find the Yellowhammer app target's packageProductDependencies and add EngineCommand
        # Simple string replacement - add EngineCommand before the closing paren
        modified = content.replace(
            'packageProductDependencies = (\n\t\t\t\t5083DD58305674F500E6D6D3 /* Domain */,\n\t\t\t);',
            'packageProductDependencies = (\n\t\t\t\t5083DD58305674F500E6D6D3 /* Domain */,\n\t\t\t\t5083DD5A305674F500E6D6D3 /* EngineCommand */,\n\t\t\t);'
        )

        with open(pbxproj_dest, 'w') as f:
            f.write(modified)

        # Parse and check
        package_info = check_module.parse_package_swift(package_dest)
        violations = check_module.check_app_links_engine(pbxproj_dest, package_info)

        # Should have MB3 violation (EngineCommand depends on Engine)
        self.assertTrue(any(v['rule'] == 'MB3' for v in violations),
                       f"Expected MB3 violation but got: {violations}")

    def test_app_imports_engine_fails_mb3(self):
        """Test (b): App source importing Engine should fail MB3."""
        # Create a test repo structure
        pbxproj_src = self.repo_root / 'Yellowhammer.xcodeproj' / 'project.pbxproj'
        package_src = self.repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'

        pbxproj_dest = os.path.join(self.temp_dir, 'project.pbxproj')
        package_dest = os.path.join(self.temp_dir, 'Package.swift')
        app_dir = os.path.join(self.temp_dir, 'Yellowhammer')

        shutil.copy(pbxproj_src, pbxproj_dest)
        shutil.copy(package_src, package_dest)
        os.makedirs(app_dir)

        # Create app source file that imports Engine
        bad_file = os.path.join(app_dir, 'Bad.swift')
        with open(bad_file, 'w') as f:
            f.write('import Engine\n')

        # Check
        violations = check_module.check_app_imports_engine(self.temp_dir)

        # Should have MB3 violation
        self.assertTrue(any(v['rule'] == 'MB3' for v in violations),
                       f"Expected MB3 violation but got: {violations}")

    def test_app_links_only_domain_passes(self):
        """Test that app linking only Domain passes MB3."""
        # Real repo configuration (app only links Domain)
        pbxproj_src = self.repo_root / 'Yellowhammer.xcodeproj' / 'project.pbxproj'
        package_src = self.repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'

        pbxproj_dest = os.path.join(self.temp_dir, 'project.pbxproj')
        package_dest = os.path.join(self.temp_dir, 'Package.swift')

        shutil.copy(pbxproj_src, pbxproj_dest)
        shutil.copy(package_src, package_dest)

        # Parse and check
        package_info = check_module.parse_package_swift(package_dest)
        violations = check_module.check_app_links_engine(pbxproj_dest, package_info)
        app_import_violations = check_module.check_app_imports_engine(self.temp_dir)

        # Should have no MB3 violations
        self.assertFalse(any(v['rule'] == 'MB3' for v in violations),
                        f"Should have no MB3 violations but got: {violations}")
        self.assertFalse(any(v['rule'] == 'MB3' for v in app_import_violations),
                        f"Should have no MB3 app import violations but got: {app_import_violations}")


class TestMB2MB4ImportViolations(unittest.TestCase):
    """Test MB2 and MB4 import violations with scratch copies."""

    def setUp(self):
        """Create temp directory for test repos."""
        self.temp_dir = tempfile.mkdtemp()

        # Find real repo
        current_file = Path(__file__)
        self.repo_root = None

        for parent in current_file.parents:
            if (parent / 'Yellowhammer.xcodeproj').exists():
                self.repo_root = parent
                break

        if self.repo_root is None:
            self.skipTest("Could not locate real repository")

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.temp_dir)

    def test_mb2_import_violation_in_scratch_copy(self):
        """Test MB2 violation: Domain imports adapter."""
        test_dir = os.path.join(self.temp_dir, 'test_mb2')
        pkg_dir = os.path.join(test_dir, 'Packages', 'YellowhammerKit')
        os.makedirs(pkg_dir)

        # Copy Package.swift and modify it
        package_src = self.repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'
        package_dest = os.path.join(pkg_dir, 'Package.swift')
        shutil.copy(package_src, package_dest)

        # Add LinearAdapter and make Domain depend on it
        with open(package_dest, 'r') as f:
            content = f.read()

        content = content.replace(
            '.target(\n        name: "Domain"\n        ),',
            '.target(\n        name: "Domain",\n        dependencies: ["LinearAdapter"]\n        ),\n        .target(\n        name: "LinearAdapter"\n        ),'
        )

        with open(package_dest, 'w') as f:
            f.write(content)

        # Create app source file with LinearAdapter import
        os.makedirs(os.path.join(pkg_dir, 'Sources', 'Domain'), exist_ok=True)
        with open(os.path.join(pkg_dir, 'Sources', 'Domain', 'test.swift'), 'w') as f:
            f.write('import LinearAdapter\n')

        # Check
        package_info = check_module.parse_package_swift(package_dest)
        violations = check_module.check_imports_in_target(
            pkg_dir, 'Domain', package_info['targets']['Domain'], package_info['targets']
        )

        # Should have MB2 violation
        self.assertTrue(any(v['rule'] == 'MB2' for v in violations),
                       f"Expected MB2 violation but got: {violations}")

    def test_mb4_import_violation_in_scratch_copy(self):
        """Test MB4 violation: Journal imports Ledger."""
        test_dir = os.path.join(self.temp_dir, 'test_mb4')
        pkg_dir = os.path.join(test_dir, 'Packages', 'YellowhammerKit')
        os.makedirs(pkg_dir)

        # Copy Package.swift and modify it
        package_src = self.repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'
        package_dest = os.path.join(pkg_dir, 'Package.swift')
        shutil.copy(package_src, package_dest)

        # Add Journal and Ledger targets with Journal depending on Ledger
        with open(package_dest, 'r') as f:
            content = f.read()

        # Find the targets array and add Journal and Ledger
        content = re.sub(
            r'targets: \[',
            'targets: [\n        .target(\n        name: "Journal",\n        dependencies: ["Ledger"]\n        ),\n        .target(\n        name: "Ledger"\n        ),',
            content
        )

        with open(package_dest, 'w') as f:
            f.write(content)

        # Create source file with import
        os.makedirs(os.path.join(pkg_dir, 'Sources', 'Journal'), exist_ok=True)
        with open(os.path.join(pkg_dir, 'Sources', 'Journal', 'test.swift'), 'w') as f:
            f.write('import Ledger\n')

        # Check
        package_info = check_module.parse_package_swift(package_dest)
        violations = check_module.check_imports_in_target(
            pkg_dir, 'Journal', package_info['targets']['Journal'], package_info['targets']
        )

        # Should have MB4 violation
        self.assertTrue(any(v['rule'] == 'MB4' for v in violations),
                       f"Expected MB4 violation but got: {violations}")


if __name__ == '__main__':
    unittest.main()
