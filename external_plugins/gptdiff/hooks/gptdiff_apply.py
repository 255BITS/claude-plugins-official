#!/usr/bin/env python3
"""
GPTDiff Apply - Python API wrapper for gptdiff plugin

Uses the gptdiff Python API instead of the CLI to generate and apply diffs.
"""

import argparse
import os
import sys

try:
    from gptdiff import (
        generate_diff,
        smartapply,
        load_project_files,
        build_environment,
        save_files,
    )
except ImportError:
    print("Error: gptdiff package not installed. Install with: pip install gptdiff", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Generate and apply diffs using gptdiff Python API")
    parser.add_argument("goal", nargs="?", help="Goal/prompt for diff generation (or read from stdin)")
    parser.add_argument("--model", "-m", help="LLM model to use")
    parser.add_argument("--dir", "-d", default=".", help="Target directory (default: current directory)")
    parser.add_argument("--dry-run", action="store_true", help="Generate diff but don't apply")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()

    # Get goal from argument or stdin
    if args.goal:
        goal = args.goal
    elif not sys.stdin.isatty():
        goal = sys.stdin.read().strip()
    else:
        print("Error: Goal is required (provide as argument or via stdin)", file=sys.stderr)
        sys.exit(1)

    if not goal:
        print("Error: Goal cannot be empty", file=sys.stderr)
        sys.exit(1)

    target_dir = os.path.abspath(args.dir)
    if not os.path.isdir(target_dir):
        print(f"Error: Target directory does not exist: {target_dir}", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(f"Target directory: {target_dir}", file=sys.stderr)
        print(f"Model: {args.model or 'default'}", file=sys.stderr)
        print(f"Goal length: {len(goal)} chars", file=sys.stderr)

    # Load project files
    if args.verbose:
        print("Loading project files...", file=sys.stderr)

    files_list = load_project_files(target_dir, target_dir)

    # Convert list of tuples to dict (load_project_files returns [(path, content), ...])
    files = {path: content for path, content in files_list}

    if not files:
        print("Warning: No files loaded from target directory", file=sys.stderr)
    elif args.verbose:
        print(f"Loaded {len(files)} files", file=sys.stderr)

    # Build environment string for LLM
    environment = build_environment(files)

    if args.verbose:
        print(f"Environment size: {len(environment)} chars", file=sys.stderr)

    # Generate diff
    if args.verbose:
        print("Generating diff...", file=sys.stderr)

    try:
        diff_kwargs = {
            "environment": environment,
            "goal": goal,
        }
        if args.model:
            diff_kwargs["model"] = args.model

        diff_text = generate_diff(**diff_kwargs)
    except Exception as e:
        print(f"Error generating diff: {e}", file=sys.stderr)
        sys.exit(1)

    if not diff_text or not diff_text.strip():
        print("No changes generated", file=sys.stderr)
        sys.exit(0)

    if args.verbose or args.dry_run:
        print("Generated diff:", file=sys.stderr)
        print("-" * 60, file=sys.stderr)
        print(diff_text, file=sys.stderr)
        print("-" * 60, file=sys.stderr)

    if args.dry_run:
        print("Dry run - not applying changes", file=sys.stderr)
        sys.exit(0)

    # Apply the diff
    if args.verbose:
        print("Applying diff...", file=sys.stderr)

    try:
        apply_kwargs = {
            "diff_text": diff_text,
            "files": files,
        }
        if args.model:
            apply_kwargs["model"] = args.model

        updated_files = smartapply(**apply_kwargs)
    except Exception as e:
        print(f"Error applying diff: {e}", file=sys.stderr)
        sys.exit(1)

    # Save updated files
    if args.verbose:
        print("Saving files...", file=sys.stderr)

    # Convert absolute paths to relative paths for save_files
    # (load_project_files returns absolute paths, save_files expects relative)
    relative_files = {}
    for path, content in updated_files.items():
        if os.path.isabs(path):
            try:
                rel_path = os.path.relpath(path, target_dir)
                relative_files[rel_path] = content
            except ValueError:
                # If path can't be made relative, use as-is
                relative_files[path] = content
        else:
            relative_files[path] = content

    try:
        save_files(relative_files, target_dir)
    except Exception as e:
        print(f"Error saving files: {e}", file=sys.stderr)
        sys.exit(1)

    # Count changes
    changed_count = sum(1 for path in updated_files if files.get(path) != updated_files.get(path))
    new_count = sum(1 for path in updated_files if path not in files)

    print(f"Applied changes: {changed_count} modified, {new_count} new files")

    if args.verbose:
        for path in updated_files:
            if path not in files:
                print(f"  + {path}")
            elif files.get(path) != updated_files.get(path):
                print(f"  M {path}")


if __name__ == "__main__":
    main()
