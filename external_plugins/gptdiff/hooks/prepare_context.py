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
    parser.add_argument("--dir", "-d", default=".", help="Target directory (default: current directory)")
    parser.add_argument("--list-only", action="store_true", help="Only list files, don't include content")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    target_dir = os.path.abspath(args.dir)
    if not os.path.isdir(target_dir):
        print(f"Error: Target directory does not exist: {target_dir}", file=sys.stderr)
        sys.exit(1)

    # Use gptdiff's file loading (respects .gptignore)
    # load_project_files returns list of (absolute_path, content) tuples
    project_files = load_project_files(target_dir, target_dir)

    # Convert to dict with relative paths
    files_dict = {}
    for abs_path, content in project_files:
        rel_path = os.path.relpath(abs_path, target_dir)
        files_dict[rel_path] = content

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
