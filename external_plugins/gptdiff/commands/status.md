---
description: "Check the status of the active GPTDiff loop"
allowed-tools: ["Bash", "Read"]
---

# GPTDiff Loop Status

Check the current loop status by running these commands:

1. **Find all active loops**:
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   find "$ROOT/.claude/start" -name "state.local.md" 2>/dev/null | while read -r state_file; do
     echo "=== Loop: $(dirname "$state_file" | xargs basename) ==="
     cat "$state_file"
     echo ""
   done
   if [[ -z "$(find "$ROOT/.claude/start" -name "state.local.md" 2>/dev/null)" ]]; then
     echo "NO_ACTIVE_LOOPS"
   fi
   ```

2. **If NO_ACTIVE_LOOPS**: Say "No GPTDiff loops are currently running."

3. **If loops are active**, also check for background jobs:
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   find "$ROOT/.claude/start" -name "pending" 2>/dev/null | while read -r pending_file; do
     PID=$(cat "$pending_file")
     LOOP_SLUG=$(dirname "$pending_file" | xargs basename)
     if kill -0 "$PID" 2>/dev/null; then
       echo "BACKGROUND_JOB: $LOOP_SLUG running (PID $PID)"
     else
       echo "BACKGROUND_JOB: $LOOP_SLUG finished"
     fi
   done
   ```

4. **Show recent changes and logs**:
   ```
   git diff --stat 2>/dev/null | tail -20
   ```

5. **Report status** with a visual summary for each loop:
   - Extract iteration, max_iterations, target_dirs, target_files, goal from the frontmatter
   - Build a progress bar: ●●●○○○○○○○ style
   - Show: iteration X of Y (Z remaining)
   - Show the targets (directories and/or files)
   - Show the goal
   - **If BACKGROUND_JOB running**: Show "⏳ External LLM processing in background (PID X)"
   - **If BACKGROUND_JOB finished**: Show "✅ Background job finished - next iteration will pick up results"
   - Show recent file changes from git diff --stat
   - Remind user: `/stop` to stop
