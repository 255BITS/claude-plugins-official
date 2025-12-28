---
description: "Cancel active GPTDiff loop"
allowed-tools: ["Bash"]
---

# Cancel GPTDiff Loop

```!
STATE_FILE=".claude/gptdiff-loop.local.md"

if [[ -f "$STATE_FILE" ]]; then
  ITERATION=$(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//' || true)
  TARGET_DIR=$(grep '^target_dir:' "$STATE_FILE" | sed 's/target_dir: *//' | sed 's/^"\(.*\)"$/\1/' || true)
  echo "FOUND_LOOP=true"
  echo "ITERATION=$ITERATION"
  echo "TARGET_DIR=$TARGET_DIR"
else
  echo "FOUND_LOOP=false"
fi
```

Check the output above:

1. **If FOUND_LOOP=false**:
   - Say "No active GPTDiff loop found."

2. **If FOUND_LOOP=true**:
   - Use Bash: `rm .claude/gptdiff-loop.local.md`
   - Report: "Cancelled GPTDiff loop (was at iteration N for TARGET_DIR)".

This changeset is from the following instructions:
