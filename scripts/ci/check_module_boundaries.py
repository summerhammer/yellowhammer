#!/usr/bin/env python3
"""
Check module boundary rules for YellowhammerKit.

Rules:
  MB1: Engine never imports adapters
  MB2: Only EngineCommand wires adapters (exception: adapter test targets can import their own)
  MB3: App never links Engine (checked via pbxproj packageProductDependencies + transitive deps)
  MB4: Journal and Ledger never depend on each other
  MB5: Engine never opens a Journal (it is handed exactly one Project's; only EngineCommand opens)

Exit codes:
  0 - All rules satisfied
  1 - One or more rules violated
"""

import argparse
import os
import re
import sys
from pathlib import Path


# Rule IDs and names
RULES = {
    'MB1': 'engine-never-imports-adapter',
    'MB2': 'only-enginecommand-wires-adapters',
    'MB3': 'app-never-links-engine',
    'MB4': 'journal-ledger-separate',
    'MB5': 'engine-never-opens-journal',
}


def is_adapter_module(name):
    """Check if a module name is an adapter (ends in Adapter or Adapters)."""
    return name.endswith('Adapter') or name.endswith('Adapters')


def is_test_target(name):
    """Check if a module name is a test target (ends in Tests)."""
    return name.endswith('Tests')


def strip_comments(line):
    """Remove line and block comment markers (simple approach)."""
    # Remove line comments
    if '//' in line:
        line = line[:line.index('//')]
    return line


def find_imports(source_code):
    """
    Find all import statements in Swift source.
    Returns: list of (module_name, line_num)
    """
    imports = []
    lines = source_code.split('\n')

    for line_num, line in enumerate(lines, 1):
        # Strip comments
        stripped = strip_comments(line).strip()

        # Look for various import patterns
        match = re.match(
            r'(@testable\s+|@_exported\s+|internal\s+|public\s+|package\s+)?import\s+(?:struct|class|func)?\s*([A-Za-z_][A-Za-z0-9_]*)',
            stripped
        )
        if match:
            module = match.group(2)
            imports.append((module, line_num))

    return imports


def parse_package_swift(package_swift_path):
    """
    Parse Package.swift to extract targets and their dependencies.
    Returns: {
        'targets': {name: {'type': 'target|testTarget|executableTarget', 'dependencies': [names], 'path': 'path/or/None', 'line': line_num}},
        'products': {name: {'type': 'library|executable', 'targets': [names]}},
    }
    """
    if not os.path.exists(package_swift_path):
        return None

    with open(package_swift_path, 'r') as f:
        content = f.read()

    targets = {}
    products = {}

    # Use a bracket matching approach to extract calls
    def extract_call_content(text, start_idx):
        """Extract content between first ( and matching )."""
        paren_depth = 0
        i = start_idx
        while i < len(text):
            if text[i] == '(':
                if paren_depth == 0:
                    start = i + 1
                paren_depth += 1
            elif text[i] == ')':
                paren_depth -= 1
                if paren_depth == 0:
                    return text[start:i], i
            i += 1
        return None, -1

    # Find line numbers for targets by counting newlines in content
    lines = content.split('\n')
    line_map = {}
    for line_num, line in enumerate(lines, 1):
        for target_type_name in ['target', 'testTarget', 'executableTarget']:
            pattern = f'.{target_type_name}('
            if pattern in line:
                # Record this line as a potential target start
                line_map[line_num] = True

    # Find all .target(, .testTarget(, .executableTarget( calls
    for target_type_name in ['target', 'testTarget', 'executableTarget']:
        pattern = f'.{target_type_name}('
        idx = content.find(pattern)
        while idx != -1:
            call_content, end_idx = extract_call_content(content, idx + len(pattern) - 1)
            if call_content:
                # Extract name
                name_match = re.search(r'name:\s*"([^"]+)"', call_content)
                if name_match:
                    target_name = name_match.group(1)
                    dependencies = []
                    path = None
                    # Calculate line number from position in content
                    target_line = content[:idx].count('\n') + 1

                    # Extract dependencies
                    deps_match = re.search(r'dependencies:\s*\[(.*?)\]', call_content, re.DOTALL)
                    if deps_match:
                        deps_str = deps_match.group(1)
                        # Extract individual dependencies
                        dep_items = re.findall(r'"([^"]+)"|\.target\(name:\s*"([^"]+)"\)|\.product\(name:\s*"([^"]+)"[^)]*\)|\.byName\(name:\s*"([^"]+)"\)', deps_str)
                        for dep_match in dep_items:
                            # dep_match is a tuple of all groups
                            dep_name = next((d for d in dep_match if d), None)
                            if dep_name:
                                dependencies.append(dep_name)

                    # Extract path
                    path_match = re.search(r'path:\s*"([^"]+)"', call_content)
                    if path_match:
                        path = path_match.group(1)

                    targets[target_name] = {
                        'type': target_type_name,
                        'dependencies': dependencies,
                        'path': path,
                        'line': target_line
                    }

            idx = content.find(pattern, idx + 1)

    # Find all .library( and .executable( calls
    for product_type_name in ['library', 'executable']:
        pattern = f'.{product_type_name}('
        idx = content.find(pattern)
        while idx != -1:
            call_content, end_idx = extract_call_content(content, idx + len(pattern) - 1)
            if call_content:
                # Extract name
                name_match = re.search(r'name:\s*"([^"]+)"', call_content)
                if name_match:
                    product_name = name_match.group(1)
                    target_names = []

                    # Extract targets
                    targets_match = re.search(r'targets:\s*\[(.*?)\]', call_content, re.DOTALL)
                    if targets_match:
                        targets_str = targets_match.group(1)
                        target_names = re.findall(r'"([^"]+)"', targets_str)

                    products[product_name] = {
                        'type': product_type_name,
                        'targets': target_names
                    }

            idx = content.find(pattern, idx + 1)

    return {
        'targets': targets,
        'products': products,
    }


def find_swift_files(directory, target_name):
    """Find all Swift source files for a target."""
    files = []

    # Try Sources/<target_name> and Tests/<target_name>
    for base_dir in ['Sources', 'Tests']:
        source_dir = os.path.join(directory, base_dir, target_name)
        if os.path.exists(source_dir):
            for root, dirs, filenames in os.walk(source_dir):
                for filename in filenames:
                    if filename.endswith('.swift'):
                        files.append(os.path.join(root, filename))

    return files


def check_imports_in_target(package_root, target_name, target_info, all_targets):
    """Check imports in a specific target."""
    violations = []

    swift_files = find_swift_files(package_root, target_name)

    for swift_file in swift_files:
        with open(swift_file, 'r') as f:
            content = f.read()

        imports = find_imports(content)

        for imported_module, line_num in imports:
            # Check if imported module is an adapter
            if is_adapter_module(imported_module):
                # MB1: Engine never imports adapters
                if target_name == 'Engine':
                    violations.append({
                        'rule': 'MB1',
                        'file': swift_file,
                        'line': line_num,
                        'message': f"Engine imports adapter {imported_module}"
                    })

                # MB2: Only EngineCommand can import adapters
                # Exception: adapter test targets can import their own adapter
                if target_name != 'EngineCommand':
                    # Check if this is an adapter test importing its own adapter
                    if is_test_target(target_name):
                        base_name = target_name.replace('Tests', '')
                        if imported_module != base_name:
                            violations.append({
                                'rule': 'MB2',
                                'file': swift_file,
                                'line': line_num,
                                'message': f"{target_name} imports wrong adapter {imported_module}"
                            })
                    else:
                        violations.append({
                            'rule': 'MB2',
                            'file': swift_file,
                            'line': line_num,
                            'message': f"{target_name} imports adapter {imported_module} (only EngineCommand can wire adapters)"
                        })

            # MB4: Journal and Ledger never depend on or import each other
            if target_name == 'Journal' and imported_module == 'Ledger':
                violations.append({
                    'rule': 'MB4',
                    'file': swift_file,
                    'line': line_num,
                    'message': "Journal imports Ledger"
                })
            elif target_name == 'Ledger' and imported_module == 'Journal':
                violations.append({
                    'rule': 'MB4',
                    'file': swift_file,
                    'line': line_num,
                    'message': "Ledger imports Journal"
                })

    return violations


def check_dependencies(package_info):
    """Check declared dependencies for violations."""
    violations = []
    targets = package_info['targets']

    for target_name, target_info in targets.items():
        dependencies = target_info.get('dependencies', [])
        target_line = target_info.get('line', 1)

        for dep in dependencies:
            # MB1: Engine never depends on adapters
            if target_name == 'Engine' and is_adapter_module(dep):
                violations.append({
                    'rule': 'MB1',
                    'target': target_name,
                    'dependency': dep,
                    'line': target_line,
                    'message': f"Engine depends on adapter {dep}"
                })

            # MB2: Only EngineCommand can depend on adapters
            if target_name != 'EngineCommand' and is_adapter_module(dep):
                # Exception: adapter test targets can depend on their own adapter
                if is_test_target(target_name):
                    base_name = target_name.replace('Tests', '')
                    if dep != base_name:
                        violations.append({
                            'rule': 'MB2',
                            'target': target_name,
                            'dependency': dep,
                            'line': target_line,
                            'message': f"{target_name} depends on wrong adapter {dep}"
                        })
                else:
                    violations.append({
                        'rule': 'MB2',
                        'target': target_name,
                        'dependency': dep,
                        'line': target_line,
                        'message': f"{target_name} depends on adapter {dep} (only EngineCommand can wire adapters)"
                    })

            # MB4: Journal and Ledger don't depend on each other
            if target_name == 'Journal' and dep == 'Ledger':
                violations.append({
                    'rule': 'MB4',
                    'target': target_name,
                    'dependency': dep,
                    'line': target_line,
                    'message': "Journal depends on Ledger"
                })
            elif target_name == 'Ledger' and dep == 'Journal':
                violations.append({
                    'rule': 'MB4',
                    'target': target_name,
                    'dependency': dep,
                    'line': target_line,
                    'message': "Ledger depends on Journal"
                })

    return violations


def parse_pbxproj_product_id_map(pbxproj_path):
    """
    Parse XCSwiftPackageProductDependency section to map IDs to product names.
    Returns: {id: product_name}
    """
    if not os.path.exists(pbxproj_path):
        return {}

    with open(pbxproj_path, 'r') as f:
        content = f.read()

    id_map = {}

    # Find XCSwiftPackageProductDependency section
    match = re.search(r'/\* Begin XCSwiftPackageProductDependency section \*/(.*?)/\* End XCSwiftPackageProductDependency section \*/', content, re.DOTALL)
    if match:
        section = match.group(1)
        # Parse each entry: ID /* ProductName */ = { ... productName = X; ... };
        for entry_match in re.finditer(r'(\w+)\s*/\*\s*([^*]+)\s*\*/\s*=\s*\{[^}]*productName\s*=\s*([^;]+);', section, re.DOTALL):
            product_id = entry_match.group(1)
            product_name = entry_match.group(3).strip()
            id_map[product_id] = product_name

    return id_map


def parse_pbxproj_app_dependencies(pbxproj_path):
    """
    Parse Xcode project to find app target's packageProductDependencies.
    Returns: list of product names the app links
    """
    if not os.path.exists(pbxproj_path):
        return []

    with open(pbxproj_path, 'r') as f:
        content = f.read()

    # Get ID to product name mapping
    id_map = parse_pbxproj_product_id_map(pbxproj_path)

    dependencies = []

    # Find PBXNativeTarget with name = Yellowhammer
    # Note: Don't require exact 24 hex digits for robustness
    match = re.search(r'=\s*\{\s*isa\s*=\s*PBXNativeTarget;[^}]*?name\s*=\s*Yellowhammer;[^}]*?packageProductDependencies\s*=\s*\((.*?)\);', content, re.DOTALL)

    if match:
        deps_str = match.group(1)
        # Extract IDs from the dependency list
        # Format: ID /* ProductName */,
        for id_match in re.finditer(r'(\w+)\s*(?:/\*\s*[^*]+\s*\*/)?', deps_str):
            product_id = id_match.group(1)
            if product_id in id_map:
                dependencies.append(id_map[product_id])

    return dependencies


def check_app_imports_engine(repo_root):
    """Check if app source files directly import Engine or EngineCommand."""
    app_dir = os.path.join(repo_root, 'Yellowhammer')
    violations = []

    if os.path.exists(app_dir):
        for root, dirs, filenames in os.walk(app_dir):
            for filename in filenames:
                if filename.endswith('.swift'):
                    filepath = os.path.join(root, filename)
                    with open(filepath, 'r') as f:
                        content = f.read()

                    imports = find_imports(content)

                    for imported_module, line_num in imports:
                        if imported_module in ['Engine', 'EngineCommand']:
                            violations.append({
                                'rule': 'MB3',
                                'file': filepath,
                                'line': line_num,
                                'message': f"App source imports {imported_module}"
                            })

    return violations


JOURNAL_OPEN_PATTERN = re.compile(r'\bJournalStore\s*\.\s*open(?:ReadOnly)?\s*\(')


def check_engine_opens_journal(package_root):
    """
    MB5: Engine source never opens a Journal. An invocation is handed exactly one Project's
    Journal by EngineCommand, so the Engine has no code path that could address a sibling's.
    Returns: list of violations
    """
    engine_dir = os.path.join(package_root, 'Sources', 'Engine')
    violations = []

    if os.path.exists(engine_dir):
        for root, dirs, filenames in os.walk(engine_dir):
            for filename in filenames:
                if filename.endswith('.swift'):
                    filepath = os.path.join(root, filename)
                    with open(filepath, 'r') as f:
                        lines = f.readlines()

                    for line_num, line in enumerate(lines, 1):
                        if JOURNAL_OPEN_PATTERN.search(strip_comments(line)):
                            violations.append({
                                'rule': 'MB5',
                                'file': filepath,
                                'line': line_num,
                                'message': "Engine opens a Journal; it must be handed its Project's by EngineCommand"
                            })

    return violations


def compute_transitive_deps(target_name, all_targets, memo=None):
    """Compute transitive dependencies of a target."""
    if memo is None:
        memo = {}

    if target_name in memo:
        return memo[target_name]

    if target_name not in all_targets:
        memo[target_name] = set()
        return memo[target_name]

    direct_deps = set(all_targets[target_name].get('dependencies', []))
    transitive = direct_deps.copy()

    for dep in direct_deps:
        transitive.update(compute_transitive_deps(dep, all_targets, memo))

    memo[target_name] = transitive
    return transitive


def check_app_links_engine(pbxproj_path, package_info):
    """
    Check if app links Engine either directly or transitively.
    Returns: list of violations
    """
    app_products = parse_pbxproj_app_dependencies(pbxproj_path)
    violations = []

    if not app_products or 'Engine' in app_products:
        if 'Engine' in app_products:
            violations.append({
                'rule': 'MB3',
                'file': pbxproj_path,
                'line': 1,
                'message': "Yellowhammer app links Engine product"
            })
        return violations

    # Map products to targets via Package.swift
    all_targets = package_info['targets']
    products = package_info['products']

    # For each product the app links, check if Engine is reachable
    for product_name in app_products:
        # Find which target(s) this product contains
        if product_name in products:
            target_names = products[product_name]['targets']
        else:
            # Fallback: assume product maps to target of same name
            target_names = [product_name]

        # Check if Engine is transitively reachable from any of these targets
        for target_name in target_names:
            transitive_deps = compute_transitive_deps(target_name, all_targets)

            if 'Engine' in transitive_deps:
                violations.append({
                    'rule': 'MB3',
                    'file': pbxproj_path,
                    'line': 1,
                    'message': f"Yellowhammer app transitively links Engine through {product_name} -> {target_name}"
                })

    return violations


def main():
    parser = argparse.ArgumentParser(
        description='Check module boundary rules'
    )
    parser.add_argument(
        '--repo-root',
        type=str,
        default=os.getcwd(),
        help='Repository root directory'
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root)
    package_swift_path = repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'
    pbxproj_path = repo_root / 'Yellowhammer.xcodeproj' / 'project.pbxproj'

    # Parse Package.swift
    package_info = parse_package_swift(str(package_swift_path))
    if package_info is None:
        print(
            f"::error file={package_swift_path},line=1,title=Module boundaries::"
            f"Cannot read {package_swift_path}",
            file=sys.stderr
        )
        return 1

    all_violations = []

    # Check dependencies declared in Package.swift
    dep_violations = check_dependencies(package_info)
    all_violations.extend(dep_violations)

    # Check imports in source files
    for target_name in package_info['targets']:
        import_violations = check_imports_in_target(
            str(repo_root / 'Packages' / 'YellowhammerKit'),
            target_name,
            package_info['targets'][target_name],
            package_info['targets']
        )
        all_violations.extend(import_violations)

    # Check MB3: app never links Engine (directly or transitively)
    app_link_violations = check_app_links_engine(str(pbxproj_path), package_info)
    all_violations.extend(app_link_violations)

    # Check MB3: app sources never import Engine/EngineCommand
    app_import_violations = check_app_imports_engine(str(repo_root))
    all_violations.extend(app_import_violations)

    # Check MB5: Engine never opens a Journal
    journal_open_violations = check_engine_opens_journal(str(repo_root / 'Packages' / 'YellowhammerKit'))
    all_violations.extend(journal_open_violations)

    # Report violations
    if all_violations:
        for violation in all_violations:
            rule_id = violation.get('rule')
            rule_name = RULES.get(rule_id, 'unknown')
            message = violation.get('message', '')
            file = violation.get('file', str(package_swift_path))
            line = violation.get('line', 1)

            print(
                f"::error file={file},line={line},title={rule_id} {rule_name}::{message}",
                file=sys.stderr
            )
        return 1

    print("Module boundary rules satisfied")
    return 0


if __name__ == '__main__':
    sys.exit(main())
