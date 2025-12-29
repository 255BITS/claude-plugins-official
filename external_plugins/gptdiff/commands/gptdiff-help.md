---
description: "Explain GPTDiff agent loop plugin and available commands"
---

# GPTDiff Loop Plugin

Run iterative improvement loops on a directory:

- Pick a **target directory** (e.g. `src/`)
- Give a **goal**
- Iterate N times (default: 3)
- Optionally run a **verification command** each iteration
- Review the final diffs

## Commands

### /gptdiff-loop

Start the loop. Run without arguments for interactive setup.

**Examples:**
```
/gptdiff-loop --dir src --goal "Improve code quality" --max-iterations 5

/gptdiff-loop --dir src --goal "Fix bugs" --cmd "npm run build" --max-iterations 3
```

### /gptdiff-status

Check the current loop progress (iteration count, goal, recent changes).

### /cancel-gptdiff-loop

Stop the current loop.

## Logs

- State: `.claude/gptdiff-loop.local.md`
- Logs: `.claude/gptdiff-loop/<target>/`
