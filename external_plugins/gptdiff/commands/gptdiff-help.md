---
description: "Explain GPTDiff agent loop plugin and available commands"
---

# GPTDiff Agent Loop Plugin Help

This plugin is built to showcase **agent loops** powered by **GPTDiff**:

- Pick a **target directory** (e.g. `items/`)
- Give a **goal**
- Iterate N times
- Optionally run an **evaluator** or **hard gate command**
- Review the final diffs

It’s “Ralph-style looping” but the work engine is **`gptdiff --apply`**, repeatedly.

## Mental model

Each iteration is:

1. (Optional) run `--eval-cmd` to generate signals (metrics/logs)
2. (Optional) run `--cmd` as a hard gate (stop when it passes)
3. run `gptdiff --apply` to make one coherent improvement
4. repeat

The big win is **convergence**: you can run:
- “make it more fun” loops
- “balance” loops
- “add variety” loops
- “polish docs/consistency” loops

…without expecting a single-shot perfect output.

## Commands

### /gptdiff-scaffold

Create `.gptignore` + interface files in a subdirectory.

**Example (game content):**
```
+/gptdiff-scaffold --dir items --template game-world
```

### /gptdiff-loop

Start the loop (Stop hook repeatedly runs `gptdiff --apply`).

**Example (creative improvement loop):**
```
+/gptdiff-loop --dir items --template game-world \
  --goal "Improve item variety and fun. Add or revise 1–3 items per iteration. Follow INTERFACE.md and RUBRIC.md." \
  --max-iterations 12
```

**Example (with evaluator):**
```
+/gptdiff-loop --dir items --template game-world \
  --goal "Balance tiers; reduce outliers; keep identity." \
  --eval-cmd "python3 tools/eval_items.py" \
  --max-iterations 10
```

**Example (hard gate command):**
```
+/gptdiff-loop --dir items --template generic \
  --goal "Fix content validation failures without weakening rules." \
  --cmd "python3 -m pytest -q" \
  --max-iterations 20
```

### /cancel-gptdiff-loop

Stops the current loop by removing its state file.

## Templates

- `generic` — a general “domain workspace interface”
- `game-world` — a flexible interface for game content (items/interactions/balance) without hardcoding a specific engine

## Logs & state

- State: `.claude/gptdiff-loop.local.md`
- Logs: `.claude/gptdiff-loop/<target-slug>/`

If you want to see what happened:
- `.claude/gptdiff-loop/<target-slug>/gptdiff.log`
- `.claude/gptdiff-loop/<target-slug>/diffstat.txt`
- `.claude/gptdiff-loop/<target-slug>/changed-files.txt`

## Best practices

- Use a branch.
- Keep iteration budgets small.
- Use an evaluator when possible (it’s the best way to “steer” loops).
- Put your “interface contract” in the directory (`INTERFACE.md`) and evolve it over time.
