# GPTDiff Plugin — Agent Loops on a Subdirectory

This plugin is for **iterating** with GPTDiff — not doing a task once, but doing it *many times* to converge on a better result.

It’s intentionally modeled after the **Ralph Wiggum** example plugin’s “loop-in-session” behavior, but instead of making the assistant implement everything directly, it drives **`gptdiff --apply`** repeatedly against a **single focused directory**.

## What you get

When you start a loop with `/gptdiff-loop`:

1. The plugin **scaffolds your target directory** (the subdirectory you pass):
   - Adds a `.gptignore` (so GPTDiff doesn’t slurp assets/build outputs)
   - Adds an `INTERFACE.md` (an explicit contract for what “good” looks like)
   - Optionally adds `RUBRIC.md` (for creative domains like game content)
2. A **Stop hook** runs the agent loop:
   - Runs optional `--eval-cmd` (signals/metrics/logs)
   - Runs optional `--cmd` (a hard gate; stops when it passes)
   - Calls `gptdiff --apply` with your goal
   - Repeats until `--max-iterations` is reached (or `--cmd` succeeds)

This pattern is ideal for “make it better” loops (fun/balance/variety/polish) where you want iterative refinement, not a single-shot answer.

## Quick start

### 1) Scaffold a game-content directory (no loop yet)

```bash
/gptdiff-scaffold --dir items --template game-world
```

### 2) Run an “improve the items” loop (fixed iteration budget)

```bash
/gptdiff-loop --dir items --template game-world \
  --goal "Iteratively improve item fun + variety. Add or revise 1–3 items per iteration. Keep balance tight and avoid power creep. Follow INTERFACE.md and RUBRIC.md." \
  --max-iterations 12
```

### 3) Run a “balance” loop with an evaluator

If you have an evaluator script (even a simple one) that prints stats, you can feed it in:

```bash
/gptdiff-loop --dir items --template game-world \
  --goal "Balance item stats across tiers; reduce outliers; keep each item distinct; update docs if needed." \
  --eval-cmd "python3 tools/eval_items.py" \
  --max-iterations 10
```

### 4) Run a “make tests pass” loop (command-gated)

```bash
/gptdiff-loop --dir items --template generic \
  --goal "Fix validation errors without removing rules." \
  --cmd "python3 -m pytest -q" \
  --max-iterations 20
```

## Why subdirectory loops?

In game development you often have a dedicated **content surface area**:

- `items/` (item definitions)
- `interactions/` (trigger/effect graphs)
- `encounters/` (spawn tables)
- `balance/` (curves + tuning)

Each is a perfect place for an agent loop:

- **Items loop:** add novelty, fix boring items, improve clarity
- **Interactions loop:** add synergies/counters, reduce degenerate combos
- **Balance loop:** tighten curves, reduce outliers, preserve identity
- **Polish loop:** improve docs, naming, consistency, schema compliance

Each loop is the same mechanism — just a different goal prompt and (optionally) a different eval command.

## Commands

- `/gptdiff-scaffold` — create `.gptignore` + interface files in a target directory
- `/gptdiff-loop` — start a loop that repeatedly calls `gptdiff --apply`
- `/cancel-gptdiff-loop` — stop the current loop (removes state file)
- `/gptdiff-help` — explanation and examples

## Where the loop stores state/logs

- Loop state: `.claude/gptdiff-loop.local.md`
- Logs per target dir: `.claude/gptdiff-loop/<target-slug>/`
  - `eval.log` (optional)
  - `cmd.log` (optional)
  - `gptdiff.log`
  - `diffstat.txt` (what changed)
  - `changed-files.txt`

## Permissions

This plugin includes a `PreToolUse` hook that auto-approves bash commands for the plugin's own scripts. This means:

- `/gptdiff-loop` and `/gptdiff-scaffold` run without manual permission prompts
- The hook only approves commands that match the plugin's script paths
- All other bash commands follow normal Claude Code permission rules

## Notes

- This loop is designed to be **reviewable**:
  - run it on a branch
  - use `git diff` / `git add -p`
  - keep iteration budgets small
- It's also designed to be **domain-flexible**:
  - the "interface" is a file you own and evolve (`INTERFACE.md`)
  - nothing is hardcoded to a specific engine or game
