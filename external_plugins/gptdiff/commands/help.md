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

### /start

Start the loop. Run without arguments for interactive setup.

**Examples:**
```
/start --dir src --goal "Improve code quality" --max-iterations 5

/start --dir src --goal "Fix bugs" --cmd "npm run build" --max-iterations 3
```

### /status

Check the current loop progress (iteration count, goal, recent changes).

### /stop

Stop the current loop.

## Logs

- State: `.claude/gptdiff-loop.local.md`
- Logs: `.claude/gptdiff-loop/<target>/`
