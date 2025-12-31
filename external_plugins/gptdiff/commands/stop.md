---
description: "Cancel active GPTDiff loop"
allowed-tools: ["Bash", "Read"]
---

# Cancel GPTDiff Loop

Check if any loops are active and cancel them:

1. **Find all active loops**:
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   STATE_FILES=$(find "$ROOT/.claude/start" -name "state.local.md" 2>/dev/null)
   if [[ -z "$STATE_FILES" ]]; then
     echo "NO_ACTIVE_LOOPS"
   else
     echo "FOUND_LOOPS:"
     echo "$STATE_FILES" | while read -r sf; do
       SLUG=$(dirname "$sf" | xargs basename)
       GOAL=$(sed -n 's/^goal: "\(.*\)"$/\1/p' "$sf" | head -1)
       ITER=$(sed -n 's/^iteration: //p' "$sf" | head -1)
       echo "  - $SLUG: iteration $ITER, goal: ${GOAL:0:50}..."
     done
   fi
   ```

2. **If NO_ACTIVE_LOOPS**: Say "No active GPTDiff loops found."

3. **If loops found**, delete all state files:
   ```
   ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   find "$ROOT/.claude/start" -name "state.local.md" -delete 2>/dev/null
   echo "All GPTDiff loops cancelled."
   ```

4. **Report**: List which loops were cancelled (slug + iteration + goal snippet).
