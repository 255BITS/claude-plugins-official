---
description: "Check the status of the active GPTDiff loop"
allowed-tools: ["Bash", "Read"]
---

# GPTDiff Loop Status

Check the current loop status by running these commands:

1. **Check if loop is active** (use git root to find state file):
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && cat "$ROOT/.claude/gptdiff-loop.local.md" 2>/dev/null || echo "NO_ACTIVE_LOOP"
   ```

2. **If NO_ACTIVE_LOOP**: Say "No GPTDiff loop is currently running."

3. **If loop is active**, also run:
   ```
   # Show recent changes
   git diff --stat 2>/dev/null | tail -20
   ```

   ```
   # Show loop logs directory
   ls -la .claude/gptdiff-start/ 2>/dev/null
   ```

4. **Report status** with a visual summary:
   - Extract iteration, max_iterations, target_dir, goal from the frontmatter
   - Build a progress bar: ●●●○○○○○○○ style
   - Show: iteration X of Y (Z remaining)
   - Show the goal
   - Show recent file changes from git diff --stat
   - Remind user: `/gptdiff-stop` to stop
