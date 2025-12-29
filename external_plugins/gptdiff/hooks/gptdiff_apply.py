#!/usr/bin/env python3
"""
GPTDiff Apply - Python API wrapper for gptdiff plugin

Uses the gptdiff Python API instead of the CLI to generate and apply diffs.
Supports image input for visual feedback loops.
"""

import argparse
import base64
import os
import sys
import threading
import time

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
    parser.add_argument("--dir", "-d", action="append", default=[], help="Target directory (can specify multiple)")
    parser.add_argument("--file", "-f", action="append", default=[], help="Target file (can specify multiple)")
    parser.add_argument("--image", "-i", action="append", default=[], help="Image file to include (can specify multiple)")
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

    # Validate at least one target
    if not args.dir and not args.file:
        args.dir = ["."]  # Default to current directory

    # Validate directories exist
    target_dirs = []
    for d in args.dir:
        target_dir = os.path.abspath(d)
        if not os.path.isdir(target_dir):
            print(f"Error: Target directory does not exist: {target_dir}", file=sys.stderr)
            sys.exit(1)
        target_dirs.append(target_dir)

    # Validate files exist
    target_files = []
    for f in args.file:
        target_file = os.path.abspath(f)
        if not os.path.isfile(target_file):
            print(f"Error: Target file does not exist: {target_file}", file=sys.stderr)
            sys.exit(1)
        target_files.append(target_file)

    if args.verbose:
        if target_dirs:
            print(f"Target directories: {', '.join(target_dirs)}", file=sys.stderr)
        if target_files:
            print(f"Target files: {', '.join(target_files)}", file=sys.stderr)
        print(f"Model: {args.model or 'default'}", file=sys.stderr)
        print(f"Goal length: ~{len(goal) // 4} tokens", file=sys.stderr)

    # Load project files from all targets
    if args.verbose:
        print("Loading project files...", file=sys.stderr)

    files = {}

    # Load from directories
    for target_dir in target_dirs:
        files_list = load_project_files(target_dir, target_dir)
        # Convert list of tuples to dict (load_project_files returns [(path, content), ...])
        for path, content in files_list:
            files[path] = content

    # Load individual files
    for target_file in target_files:
        try:
            with open(target_file, 'r', encoding='utf-8', errors='replace') as f:
                files[target_file] = f.read()
        except Exception as e:
            print(f"Warning: Could not read file {target_file}: {e}", file=sys.stderr)

    if not files:
        print("Warning: No files loaded from targets", file=sys.stderr)
    elif args.verbose:
        print(f"Loaded {len(files)} files", file=sys.stderr)

    # Build environment string for LLM
    environment = build_environment(files)

    if args.verbose:
        print(f"Environment size: ~{len(environment) // 4} tokens", file=sys.stderr)

    # Load images if provided
    images = []
    for image_path in args.image:
        abs_image_path = os.path.abspath(image_path)
        if not os.path.isfile(abs_image_path):
            print(f"Warning: Image file does not exist: {abs_image_path}", file=sys.stderr)
            continue
        try:
            with open(abs_image_path, 'rb') as f:
                image_data = f.read()
            # Detect media type from extension
            ext = os.path.splitext(abs_image_path)[1].lower()
            media_types = {
                '.png': 'image/png',
                '.jpg': 'image/jpeg',
                '.jpeg': 'image/jpeg',
                '.gif': 'image/gif',
                '.webp': 'image/webp',
            }
            media_type = media_types.get(ext, 'image/png')
            # Encode as base64
            image_b64 = base64.b64encode(image_data).decode('utf-8')
            images.append({
                'type': 'base64',
                'media_type': media_type,
                'data': image_b64,
            })
            if args.verbose:
                print(f"Loaded image: {abs_image_path} ({media_type}, {len(image_data)} bytes)", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Could not load image {abs_image_path}: {e}", file=sys.stderr)

    if args.verbose and images:
        print(f"Sending {len(images)} image(s) with request", file=sys.stderr)

    # Generate diff with heartbeat to prevent timeout
    print("📤 Sending to LLM...", file=sys.stderr)
    sys.stderr.flush()

    # Heartbeat thread to show progress during long LLM calls
    stop_heartbeat = threading.Event()
    def heartbeat():
        dots = 0
        while not stop_heartbeat.wait(5):  # Every 5 seconds
            dots += 1
            print(f"   ...waiting ({dots * 5}s)", file=sys.stderr)
            sys.stderr.flush()

    heartbeat_thread = threading.Thread(target=heartbeat, daemon=True)
    heartbeat_thread.start()

    try:
        diff_kwargs = {
            "environment": environment,
            "goal": goal,
        }
        if args.model:
            diff_kwargs["model"] = args.model
        if images:
            diff_kwargs["images"] = images

        diff_text = generate_diff(**diff_kwargs)
        stop_heartbeat.set()
        print("📥 Response received", file=sys.stderr)
    except Exception as e:
        stop_heartbeat.set()
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

    # For multiple targets, we need to check if each file falls within a valid target
    # and save with appropriate relative paths
    def is_within_targets(filepath):
        """Check if a file path is within any of the specified targets."""
        abs_path = os.path.abspath(filepath)

        # Check against target directories
        for tdir in target_dirs:
            try:
                rel = os.path.relpath(abs_path, tdir)
                if not rel.startswith('..'):
                    return True, tdir, rel
            except ValueError:
                pass

        # Check against individual target files
        for tfile in target_files:
            if abs_path == tfile:
                return True, os.path.dirname(tfile), os.path.basename(tfile)

        return False, None, None

    skipped_files = []
    saved_count = 0

    for path, content in updated_files.items():
        abs_path = os.path.abspath(path) if not os.path.isabs(path) else path
        is_valid, base_dir, rel_path = is_within_targets(abs_path)

        if not is_valid:
            skipped_files.append(path)
            continue

        # Save the file directly (we have absolute paths)
        try:
            os.makedirs(os.path.dirname(abs_path), exist_ok=True)
            with open(abs_path, 'w', encoding='utf-8') as f:
                f.write(content)
            saved_count += 1
            if args.verbose:
                print(f"  Saved: {path}", file=sys.stderr)
        except Exception as e:
            print(f"Error saving file {path}: {e}", file=sys.stderr)

    if skipped_files:
        print(f"⚠️  Skipped {len(skipped_files)} files outside target scope:", file=sys.stderr)
        for f in skipped_files[:5]:
            print(f"   - {f}", file=sys.stderr)
        if len(skipped_files) > 5:
            print(f"   ... and {len(skipped_files) - 5} more", file=sys.stderr)

    # Count changes - compare updated_files to original files
    changed_count = 0
    new_count = 0
    changed_paths = []
    new_paths = []

    for path, content in updated_files.items():
        abs_path = os.path.abspath(path) if not os.path.isabs(path) else path
        is_valid, _, _ = is_within_targets(abs_path)
        if not is_valid:
            continue  # Skip files outside scope

        if abs_path in files:
            if files[abs_path] != content:
                changed_count += 1
                changed_paths.append(path)
        else:
            new_count += 1
            new_paths.append(path)

    print(f"✅ Applied changes: {changed_count} modified, {new_count} new files")

    if args.verbose or (changed_count + new_count) > 0:
        for path in new_paths:
            print(f"  + {path}", file=sys.stderr)
        for path in changed_paths:
            print(f"  M {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
