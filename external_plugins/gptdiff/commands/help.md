---
description: "Explain agent loop plugin and available commands"
---

# Agent Loop Plugin

Run iterative improvement loops on a directory:

- Pick a **target directory** (e.g. `src/`)
- Give a **goal**
- Iterate N times (default: 5)
- Optionally run a **feedback command** between iterations
- Review the final diffs

## Commands

### /start

Start the loop. Run without arguments for **interactive setup** that asks about:
- Goal (with smart suggestions based on code analysis)
- Number of iterations (5/15/40)
- Agent feedback (enabled by default)

**Options:**
- `--dir PATH` - Target directory (can specify multiple)
- `--file PATH` - Target file (can specify multiple)
- `--goal TEXT` - Goal prompt (required)
- `--max-iterations N` - Stop after N iterations (default: 5)
- `--feedback-cmd CMD` - Run after each iteration, output feeds into next
- `--feedback-image PATH` - Image file to include in each iteration
- `--feedback-agent` - Enable subagent feedback (default: enabled)
- `--no-feedback-agent` - Disable subagent spawning (not recommended)
- `--eval-cmd CMD` - Optional evaluator command (signals only)

**Examples:**
```
# Basic loop
/start --dir src --goal "Improve code quality" --max-iterations 5

# With feedback command (test runners, etc.)
/start --dir src --goal "Fix failing tests" \
  --feedback-cmd "npm test 2>&1 | tail -50" --max-iterations 5

# Visual feedback with image
/start --dir game/ui --goal "Improve UI" \
  --feedback-cmd "screenshot-tool /tmp/ui.png" \
  --feedback-image /tmp/ui.png --max-iterations 5

# Subagent spawning is enabled by default (no flag needed)
/start --dir src --goal "Improve code quality" --max-iterations 5

# To disable subagent spawning (not recommended)
/start --dir src --goal "Quick fix" --no-feedback-agent
```

### /status

Check the current loop progress (iteration count, goal, recent changes, session ownership).

### /stop

Stop all loops in this repository. Useful for cleaning up orphaned loops from closed sessions.

## Session Isolation

**Loops are now session-specific.** A loop started in one Claude Code session will NOT run in another session.

**Why?** This prevents the "hijacking" problem where a loop from one terminal would suddenly appear in a different terminal/session.

**What this means:**
- Each loop is tied to the session that started it
- If you close your terminal, the loop becomes "orphaned"
- Orphaned loops won't run in new sessions - they just sit there
- Use `/stop` to clean up orphaned loops
- Use `/status` to see which sessions own which loops

**Common scenarios:**
- **Loop not running?** Check `/status` - you may need to restart with `/start`
- **"Owned by another session" warning?** Use `/stop` to clean up, then `/start` again
- **Multiple terminals?** Each needs its own `/start` command

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

This lets Claude decide what feedback to gather without pre-configuring commands.

## Subagent Perspectives (enabled by default)

Each iteration spawns a **subagent** to provide fresh perspectives. This prevents the main agent from getting stuck in local optima.

**How it works:**
1. Main agent spawns a subagent from its available agents
2. Subagent analyzes the code and recommends ONE specific improvement
3. Main agent implements the recommendation
4. Next iteration continues the process

**Options:**
- `--feedback-agent` (default) - Claude picks an appropriate subagent each iteration
- `--no-feedback-agent` - Disable (not recommended - loses diversity of perspectives)

## Logs

Each loop has its own directory (multiple loops can run concurrently):

- State: `.claude/start/<target-slug>/state.local.md`
- Logs: `.claude/start/<target-slug>/`
  - `eval.log` - Evaluator output
  - `feedback.log` - Feedback command output
  - `agent-feedback.txt` - Subagent feedback
  - `gptdiff.log` - Inference log
  - `diffstat.txt` - Changes summary
