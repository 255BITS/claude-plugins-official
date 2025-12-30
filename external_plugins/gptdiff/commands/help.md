---
description: "Explain GPTDiff agent loop plugin and available commands"
---

# GPTDiff Loop Plugin

Run iterative improvement loops on a directory:

- Pick a **target directory** (e.g. `src/`)
- Give a **goal**
- Iterate N times (default: 3)
- Optionally run a **feedback command** between iterations
- Review the final diffs

## Commands

### /start

Start the loop. Run without arguments for **interactive setup** that asks about:
- Target directories/files
- Goal (with smart suggestions based on code analysis)
- Number of iterations (3/5/10)
- Agent feedback (auto, specific agent from /agents, or none)

**Options:**
- `--dir PATH` - Target directory (can specify multiple)
- `--file PATH` - Target file (can specify multiple)
- `--goal TEXT` - Goal prompt (required)
- `--max-iterations N` - Stop after N iterations (default: 3)
- `--feedback-cmd CMD` - Run after each iteration, output feeds into next
- `--feedback-image PATH` - Image file to include in each iteration
- `--feedback-agent AGENT` - Spawn expert agent to review changes ("auto" lets Claude decide, or pass a custom description)
- `--eval-cmd CMD` - Optional evaluator command (signals only)
- `--inference-mode MODE` - "claude" (default) or "external" LLM

**Examples:**
```
# Basic loop
/start --dir src --goal "Improve code quality" --max-iterations 5

# With feedback command (test runners, etc.)
/start --dir src --goal "Fix failing tests" \
  --feedback-cmd "npm test 2>&1 | tail -50" --max-iterations 3

# Visual feedback with image
/start --dir game/ui --goal "Improve UI" \
  --feedback-cmd "screenshot-tool /tmp/ui.png" \
  --feedback-image /tmp/ui.png --max-iterations 5

# Agent feedback (Claude picks an appropriate agent each iteration)
/start --dir src --goal "Improve code quality" \
  --feedback-agent auto --max-iterations 5
```

### /status

Check the current loop progress (iteration count, goal, recent changes).

### /stop

Stop the current loop.

## Feedback Between Iterations

The `--feedback-cmd` flag runs a command after each iteration completes. The output is included in the next iteration's prompt.

The `--feedback-image` flag includes an image file in each iteration, enabling visual feedback:

- **Screenshot feedback**: Capture UI state after each change
- **Visual diff**: Show before/after comparisons
- **Game testing**: Simulation screenshots, gameplay previews

Both text and image feedback work together - use both for rich feedback loops.

Supported image formats: PNG, JPEG, GIF, WebP

## Auto-Detected Feedback Images

Claude can save images to a known path, and the loop will automatically include them:

- **Path**: `.claude/start/<slug>/feedback-image.png` (or .jpg/.gif/.webp)
- **Auto-detection**: Always enabled - images found here are included in next iteration
- **Works with both modes**: Claude Code and external LLMs

This lets Claude decide what feedback to gather without pre-configuring commands.

## Expert Agent Feedback

Use `--feedback-agent` to spawn an agent to review changes each iteration.

- **auto**: Claude picks an appropriate agent each iteration based on the goal and changes made

Examples:
```
--feedback-agent auto
```

## Logs

- State: `.claude/start.local.md`
- Logs: `.claude/start/<target-slug>/`
  - `eval.log` - Evaluator output
  - `feedback.log` - Feedback command output
  - `agent-feedback.txt` - Expert agent feedback
  - `gptdiff.log` - LLM inference log
  - `diffstat.txt` - Changes summary
