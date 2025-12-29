#!/usr/bin/env python3
"""
Prepare context for Claude Code using gptdiff's file loading utilities.

This script reuses gptdiff's load_project_files() and build_environment()
to prepare file context, but delegates the actual diff generation to
Claude Code's inference instead of making separate LLM API calls.
"""

import argparse
import json
import os
import sys

try:
    from gptdiff import load_project_files, build_environment
except ImportError:
    print("Error: gptdiff package not installed. Install with: pip install gptdiff", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Prepare file context for Claude Code")
    parser.add_argument("--dir", "-d", action="append", default=[], help="Target directory (can specify multiple)")
    parser.add_argument("--file", "-f", action="append", default=[], help="Target file (can specify multiple)")
    parser.add_argument("--list-only", action="store_true", help="Only list files, don't include content")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    # Validate at least one target is specified
    if not args.dir and not args.file:
        # Default to current directory if nothing specified
        args.dir = ["."]

    # Collect all files from all targets
    files_dict = {}

    # Process directories
    for target_dir in args.dir:
        target_dir = os.path.abspath(target_dir)
        if not os.path.isdir(target_dir):
            print(f"Error: Target directory does not exist: {target_dir}", file=sys.stderr)
            sys.exit(1)

        # Use gptdiff's file loading (respects .gptignore)
        # load_project_files returns list of (absolute_path, content) tuples
        project_files = load_project_files(target_dir, target_dir)

        # Convert to dict with paths relative to the target directory
        for abs_path, content in project_files:
            # Use path relative to the target dir, prefixed with the target dir name
            rel_to_target = os.path.relpath(abs_path, target_dir)
            # Get the target dir basename to prefix the path
            target_basename = os.path.basename(target_dir.rstrip('/'))
            if target_basename and target_basename != '.':
                key = os.path.join(target_basename, rel_to_target)
            else:
                key = rel_to_target
            files_dict[key] = content

    # Process individual files
    for target_file in args.file:
        target_file = os.path.abspath(target_file)
        if not os.path.isfile(target_file):
            print(f"Error: Target file does not exist: {target_file}", file=sys.stderr)
            sys.exit(1)

        try:
            with open(target_file, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
            # Use just the filename as key
            files_dict[os.path.basename(target_file)] = content
        except Exception as e:
            print(f"Warning: Could not read file {target_file}: {e}", file=sys.stderr)

    if args.json:
        if args.list_only:
            output = {"files": list(files_dict.keys())}
        else:
            output = {"files": files_dict}
        print(json.dumps(output, indent=2))
    elif args.list_only:
        for path in sorted(files_dict.keys()):
            print(path)
    else:
        # Use gptdiff's environment builder
        environment = build_environment(files_dict)
        print(environment)


if __name__ == "__main__":
    main()
