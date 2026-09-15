#!/usr/bin/env python3
"""
Check for deployment target consistency across Xcode project and Swift package.

Validates that:
  - All MACOSX_DEPLOYMENT_TARGET values in Yellowhammer.xcodeproj are equal
  - The macOS platform in Packages/YellowhammerKit/Package.swift matches
  - Version normalization handles .v26, 26.0, 26.5, etc. correctly

Exit codes:
  0 - All targets match
  1 - Mismatch or missing values
"""

import argparse
import os
import re
import sys
from pathlib import Path


def normalize_version(version_str):
    """
    Normalize version strings to X.Y.Z format.
    Handles: "26.5", ".v26", ".v26_5", ".v15", etc.
    Returns: tuple (major, minor, patch) for comparison.
    """
    # Handle .vX and .vX_Y formats
    if version_str.startswith('.v'):
        version_str = version_str[2:]

    # Replace underscore with dot
    version_str = version_str.replace('_', '.')

    # Remove any quotes
    version_str = version_str.strip('"\'')

    parts = version_str.split('.')
    major = int(parts[0]) if len(parts) > 0 else 0
    minor = int(parts[1]) if len(parts) > 1 else 0
    patch = int(parts[2]) if len(parts) > 2 else 0

    return (major, minor, patch)


def format_version(normalized_tuple):
    """Format a normalized version tuple back to string."""
    major, minor, patch = normalized_tuple
    if patch == 0:
        return f"{major}.{minor}"
    return f"{major}.{minor}.{patch}"


def check_pbxproj_targets(pbxproj_path):
    """
    Extract all MACOSX_DEPLOYMENT_TARGET values from pbxproj.
    Returns: (list of values, list of (line_num, value, file_path))
    """
    if not os.path.exists(pbxproj_path):
        return None, []

    values = []
    line_info = []

    with open(pbxproj_path, 'r') as f:
        for line_num, line in enumerate(f, 1):
            match = re.search(r'MACOSX_DEPLOYMENT_TARGET\s*=\s*([^;]+);', line)
            if match:
                value = match.group(1).strip()
                values.append(value)
                line_info.append((line_num, value, pbxproj_path))

    return values if values else None, line_info


def check_package_swift_platform(package_swift_path):
    """
    Extract macOS platform from Package.swift.
    Returns: (version_string or None, line_num, file_path)
    """
    if not os.path.exists(package_swift_path):
        return None, None, None

    with open(package_swift_path, 'r') as f:
        in_platforms = False
        for line_num, line in enumerate(f, 1):
            # Look for platforms: [ or .platforms([
            if 'platforms' in line and ('[' in line or '(' in line):
                in_platforms = True

            if in_platforms:
                # Look for .macOS(...) pattern
                match = re.search(r'\.macOS\(([^)]+)\)', line)
                if match:
                    version = match.group(1).strip().strip('"\'')
                    return version, line_num, package_swift_path

                # Exit platforms block if we see closing bracket/paren
                if ']' in line or ')' in line:
                    in_platforms = False

    return None, None, None


def main():
    parser = argparse.ArgumentParser(
        description='Check deployment target consistency'
    )
    parser.add_argument(
        '--repo-root',
        type=str,
        default=os.getcwd(),
        help='Repository root directory'
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root)
    pbxproj_path = repo_root / 'Yellowhammer.xcodeproj' / 'project.pbxproj'
    package_swift_path = repo_root / 'Packages' / 'YellowhammerKit' / 'Package.swift'

    # Check pbxproj
    pbxproj_values, pbxproj_lines = check_pbxproj_targets(str(pbxproj_path))

    if pbxproj_values is None:
        print(
            f"::error file={pbxproj_path},line=1,title=Deployment target::"
            f"No MACOSX_DEPLOYMENT_TARGET found in {pbxproj_path}",
            file=sys.stderr
        )
        return 1

    # Check that all pbxproj values are equal
    normalized_pbxproj = [normalize_version(v) for v in pbxproj_values]
    if len(set(normalized_pbxproj)) > 1:
        print(
            f"::error file={pbxproj_path},line={pbxproj_lines[0][0]},title=Deployment target::"
            f"Multiple MACOSX_DEPLOYMENT_TARGET values in {pbxproj_path}: "
            f"{', '.join(pbxproj_values)}",
            file=sys.stderr
        )
        return 1

    pbxproj_normalized = normalized_pbxproj[0]

    # Check package.swift
    package_version, package_line, _ = check_package_swift_platform(str(package_swift_path))

    if package_version is None:
        print(
            f"::error file={package_swift_path},line=1,title=Deployment target::"
            f"No macOS platform found in {package_swift_path}",
            file=sys.stderr
        )
        return 1

    package_normalized = normalize_version(package_version)

    # Compare
    if pbxproj_normalized != package_normalized:
        pbxproj_formatted = format_version(pbxproj_normalized)
        package_formatted = format_version(package_normalized)
        print(
            f"::error file={pbxproj_path},line={pbxproj_lines[0][0]},title=Deployment target::"
            f"Deployment target mismatch: {pbxproj_path} has {pbxproj_formatted}, "
            f"but {package_swift_path} has {package_formatted}",
            file=sys.stderr
        )
        return 1

    # Success
    formatted = format_version(pbxproj_normalized)
    print(f"Deployment target: {formatted}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
