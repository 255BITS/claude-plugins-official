---
description: "Cancel active GPTDiff loop"
allowed-tools: ["Bash", "Read"]
---

# Cancel GPTDiff Loop

Check if a loop is active by reading the state file:

1. First, check if `.claude/gptdiff-loop.local.md` exists using:
   ```
   cat .claude/gptdiff-loop.local.md 2>/dev/null || echo "NO_LOOP_FOUND"
   ```

2. **If NO_LOOP_FOUND**: Say "No active GPTDiff loop found."

3. **If file exists**:
   - Note the iteration and target_dir from the frontmatter
   - Delete the state file: `rm .claude/gptdiff-loop.local.md`
   - Report: "Cancelled GPTDiff loop (was at iteration N for TARGET_DIR)."
