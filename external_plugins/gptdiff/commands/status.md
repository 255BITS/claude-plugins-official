---
description: "Check the status of the active GPTDiff loop"
allowed-tools: ["Bash", "Read"]
---

# GPTDiff Loop Status

Check the current loop status by running these commands:

1. **Check if loop is active** (use git root to find state file):
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && cat "$ROOT/.claude/start.local.md" 2>/dev/null || echo "NO_ACTIVE_LOOP"
   ```

2. **If NO_ACTIVE_LOOP**: Say "No GPTDiff loop is currently running."

3. **If loop is active**, also check for background job:
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   # Find any pending file in the start directory
   PENDING=$(find "$ROOT/.claude/start" -name "pending" 2>/dev/null | head -1)
   if [[ -f "$PENDING" ]]; then
     PID=$(cat "$PENDING")
     if kill -0 "$PID" 2>/dev/null; then
       echo "BACKGROUND_JOB=running (PID $PID)"
     else
       echo "BACKGROUND_JOB=finished"
     fi
   else
     echo "BACKGROUND_JOB=none"
   fi
   ```

4. **Show recent changes and logs**:
   ```
   git diff --stat 2>/dev/null | tail -20
   ```

5. **Report status** with a visual summary:
   - Extract iteration, max_iterations, target_dirs, target_files, goal from the frontmatter
   - Build a progress bar: ●●●○○○○○○○ style
   - Show: iteration X of Y (Z remaining)
   - Show the targets (directories and/or files)
   - Show the goal
   - **If BACKGROUND_JOB=running**: Show "⏳ External LLM processing in background (PID X)"
   - **If BACKGROUND_JOB=finished**: Show "✅ Background job finished - next iteration will pick up results"
   - Show recent file changes from git diff --stat
   - Remind user: `/stop` to stop
