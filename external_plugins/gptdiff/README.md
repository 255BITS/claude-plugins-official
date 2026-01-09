# CEO Plugin — Agent Loops for Iterative Improvement

This plugin runs **iterative improvement loops** using Claude Code — not doing a task once, but doing it *many times* to converge on a better result.

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
/start --dir src --dir lib --goal "Refactor shared code" --max-iterations 5
```

### Specific files

```bash
/start --file src/main.ts --file src/utils.ts --goal "Optimize these files" --max-iterations 5
```

## Options

```
--dir PATH              Target directory (can specify multiple)
--file PATH             Target file (can specify multiple)
--goal TEXT             Goal prompt (required)
--max-iterations N      Stop after N iterations (default: 5, 0 = unlimited)
--eval-cmd CMD          Optional evaluator command (signals only)
--feedback-cmd CMD      Run after each iteration, output feeds into next
--feedback-image PATH   Image file to include in each iteration's context
--feedback-agent        Enable subagent feedback (default: enabled)
--no-feedback-agent     Disable subagent feedback
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

### Agent-based feedback (default)

Each iteration, Claude spawns a subagent from its available agents to provide feedback on the changes.

```bash
# Subagent feedback is enabled by default
/start --dir src --goal "Improve code quality" --max-iterations 5

# Disable subagent feedback
/start --dir src --goal "Improve code quality" --no-feedback-agent --max-iterations 5
```

## Where state and logs are stored

Each loop has its own directory based on target hash, allowing multiple concurrent loops:

- Loop state: `.claude/start/<target-slug>/state.local.md`
- Logs: `.claude/start/<target-slug>/`
  - `eval.log`, `feedback.log`, `ceo.log`
  - `diffstat.txt`, `changed-files.txt`

## Notes

- Run loops on a branch for easy review with `git diff`
- Keep iteration budgets small and reviewable
- Uses gptdiff's `.gptignore` patterns for file discovery
