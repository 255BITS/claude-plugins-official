# GPTDiff Plugin — Agent Loops for Iterative Improvement

This plugin runs **iterative improvement loops** using GPTDiff — not doing a task once, but doing it *many times* to converge on a better result.

## Commands

- `/start` — Start an iterative improvement loop
- `/stop` — Cancel the current loop
- `/status` — Check loop progress
- `/help` — Show help and examples

## Quick start

### Basic loop

```bash
/start --dir src --goal "Improve code quality" --max-iterations 5
```

### Multiple targets

```bash
/start --dir src --dir lib --goal "Refactor shared code" --max-iterations 3
```

### Specific files

```bash
/start --file src/main.ts --file src/utils.ts --goal "Optimize these files" --max-iterations 3
```

## Options

```
--dir PATH              Target directory (can specify multiple)
--file PATH             Target file (can specify multiple)
--goal TEXT             Goal prompt (required)
--max-iterations N      Stop after N iterations (default: 3, 0 = unlimited)
--inference-mode MODE   "claude" (default) or "external" LLM
--eval-cmd CMD          Optional evaluator command (signals only)
--feedback-cmd CMD      Run after each iteration, output feeds into next
--feedback-image PATH   Image file to include in each iteration's context
--feedback-agent AGENT  Agent to review changes each iteration
```

## Feedback options

### Test runner feedback

```bash
/start --dir src --goal "Fix failing tests" \
  --feedback-cmd "npm test 2>&1 | tail -50" \
  --max-iterations 5
```

### Visual feedback with images

```bash
/start --dir game/ui --goal "Improve UI aesthetics" \
  --feedback-cmd "screenshot-tool --output /tmp/ui.png" \
  --feedback-image /tmp/ui.png \
  --max-iterations 5
```

### Agent-based feedback

Use `--feedback-agent` to have Claude spawn a specialized agent to review changes each iteration.

**IMPORTANT**: Only use agents that exist in your `/agents` directory. Run `/agents` to see available agents.

```bash
# Auto-select agent (Claude picks from available agents)
/start --dir src --goal "Improve code quality" \
  --feedback-agent auto --max-iterations 5

# Specific agent (must exist in /agents)
/start --dir src --goal "Review error handling" \
  --feedback-agent code-reviewer --max-iterations 5
```

With `--feedback-agent auto`, Claude picks the most appropriate agent from the catalog each iteration.

## Inference modes

### Claude Code mode (default)

When `GPTDIFF_LLM_API_KEY` is **not set**, Claude Code makes improvements directly using its Edit/Write tools.

### External LLM mode

When `GPTDIFF_LLM_API_KEY` **is set**, the plugin uses gptdiff's Python API to call an external LLM:

```bash
export GPTDIFF_LLM_API_KEY="your-api-key"
export GPTDIFF_MODEL="deepseek-reasoner"  # optional
```

## Where state and logs are stored

- Loop state: `.claude/start.local.md`
- Logs: `.claude/start/<target-slug>/`
  - `eval.log`, `feedback.log`, `gptdiff.log`
  - `diffstat.txt`, `changed-files.txt`

## Notes

- Run loops on a branch for easy review with `git diff`
- Keep iteration budgets small and reviewable
- Uses gptdiff's `.gptignore` patterns for file discovery
