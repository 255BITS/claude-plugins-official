#!/bin/bash

# GPTDiff Loop Setup Script
# - scaffolds the target dir (so it has .gptignore + interface contract)
# - writes .claude/gptdiff-loop.local.md (state consumed by stop hook)

set -euo pipefail

show_help() {
  cat << 'HELP_EOF'
GPTDiff Loop (Agent Loop)

USAGE:
  /gptdiff-loop --dir PATH --goal "..." [OPTIONS]

OPTIONS:
  --dir PATH                   Target subdirectory to work on (required)
  --goal TEXT                  Goal prompt for GPTDiff (required)
  --template NAME              generic | game-world (default: generic)
  --max-iterations N           Stop after N iterations (default: 10, 0 = unlimited)
  --eval-cmd CMD               Optional evaluator command (signals only; never gates stop)
  --cmd CMD                    Optional hard gate command (loop stops when it returns 0)
  --model MODEL                Optional GPTDiff model override
  --overwrite-scaffold          Overwrite .gptignore / INTERFACE.md / RUBRIC.md in target dir
  -h, --help                   Show help

EXAMPLES:
  /gptdiff-loop --dir items --template game-world \
    --goal "Improve item fun + variety. Add or revise 1–3 items per iteration. Use INTERFACE.md and RUBRIC.md." \
    --max-iterations 12

  /gptdiff-loop --dir items --template game-world \
    --goal "Balance tiers; reduce outliers; keep identity." \
    --eval-cmd "python3 tools/eval_items.py" \
    --max-iterations 10

  /gptdiff-loop --dir items --template generic \
    --goal "Fix validation failures without weakening rules." \
    --cmd "python3 -m pytest -q" \
    --max-iterations 20
HELP_EOF
}
TARGET_DIR=""
GOAL=""
TEMPLATE="generic"
MAX_ITERATIONS="10"
EVAL_CMD="null"
CMD="null"
MODEL="null"
OVERWRITE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --dir)
      TARGET_DIR="${2:-}"
      shift 2
      ;;
    --goal)
      GOAL="${2:-}"
      shift 2
      ;;
    --template)
      TEMPLATE="${2:-}"
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="${2:-}"
      shift 2
      ;;
    --eval-cmd)
      EVAL_CMD="${2:-}"
      shift 2
      ;;
    --cmd)
      CMD="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --overwrite-scaffold)
      OVERWRITE="true"
      shift
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "   Try: /gptdiff-loop --help" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  echo "❌ Error: --dir PATH is required" >&2
  exit 1
fi

if [[ -z "$GOAL" ]]; then
  echo "❌ Error: --goal TEXT is required" >&2
  exit 1
fi

case "$TEMPLATE" in
  generic|game-world) ;;
  *)
    echo "❌ Error: --template must be 'generic' or 'game-world' (got: $TEMPLATE)" >&2
    exit 1
    ;;
esac

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: --max-iterations must be an integer (0 = unlimited), got: $MAX_ITERATIONS" >&2
  exit 1
fi

if ! command -v gptdiff >/dev/null 2>&1; then
  echo "❌ Error: 'gptdiff' not found on PATH. Install with: pip install gptdiff" >&2
  exit 1
fi

# Scaffold target directory (creates .gptignore + interface contract)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAFFOLD_ARGS=(--dir "$TARGET_DIR" --template "$TEMPLATE")
if [[ "$OVERWRITE" == "true" ]]; then
  SCAFFOLD_ARGS+=(--overwrite)
fi
"$SCRIPT_DIR/scaffold-loop-dir.sh" "${SCAFFOLD_ARGS[@]}"

mkdir -p .claude

yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  echo "$s"
}

TARGET_DIR_ESC="$(yaml_escape "$TARGET_DIR")"
GOAL_ESC="$(yaml_escape "$GOAL")"
TEMPLATE_ESC="$(yaml_escape "$TEMPLATE")"

if [[ -n "${EVAL_CMD:-}" ]] && [[ "$EVAL_CMD" != "null" ]]; then
  EVAL_CMD_ESC="$(yaml_escape "$EVAL_CMD")"
  EVAL_CMD_YAML="\"$EVAL_CMD_ESC\""
else
  EVAL_CMD_YAML="null"
fi

if [[ -n "${CMD:-}" ]] && [[ "$CMD" != "null" ]]; then
  CMD_ESC="$(yaml_escape "$CMD")"
  CMD_YAML="\"$CMD_ESC\""
else
  CMD_YAML="null"
fi

if [[ -n "${MODEL:-}" ]] && [[ "$MODEL" != "null" ]]; then
  MODEL_ESC="$(yaml_escape "$MODEL")"
  MODEL_YAML="\"$MODEL_ESC\""
else
  MODEL_YAML="null"
fi

cat > .claude/gptdiff-loop.local.md <<EOF
---
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
target_dir: "$TARGET_DIR_ESC"
goal: "$GOAL_ESC"
template: "$TEMPLATE_ESC"
eval_cmd: $EVAL_CMD_YAML
cmd: $CMD_YAML
model: $MODEL_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
 
GPTDiff loop is active.
 
Please reply with a short progress note (or just \`ok\`) and then stop.
To cancel: /cancel-gptdiff-loop
EOF

cat <<EOF

🔁 GPTDiff loop activated!

Target directory: $TARGET_DIR
Template: $TEMPLATE
Max iterations: $(if [[ "$MAX_ITERATIONS" -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
Eval command: $(if [[ "$EVAL_CMD_YAML" != "null" ]]; then echo "$EVAL_CMD"; else echo "none"; fi)
Hard gate cmd: $(if [[ "$CMD_YAML" != "null" ]]; then echo "$CMD"; else echo "none"; fi)
Model: $(if [[ "$MODEL_YAML" != "null" ]]; then echo "$MODEL"; else echo "default"; fi)

State file:
  .claude/gptdiff-loop.local.md

Logs:
  .claude/gptdiff-loop/<target-slug>/

Tip:
  Keep iteration budgets small and review with:
    git diff
    git add -p
EOF
