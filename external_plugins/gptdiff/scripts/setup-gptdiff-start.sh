#!/bin/bash

# GPTDiff Loop Setup Script
# Writes .claude/gptdiff-start.local.md (state consumed by stop hook)

set -euo pipefail

show_help() {
  cat << 'HELP_EOF'
GPTDiff Loop (Agent Loop)

USAGE:
  /gptdiff-start --dir PATH --goal "..." [OPTIONS]

OPTIONS:
  --dir PATH                   Target subdirectory to work on (required)
  --goal TEXT                  Goal prompt for GPTDiff (required)
  --max-iterations N           Stop after N iterations (default: 3, 0 = unlimited)
  --eval-cmd CMD               Optional evaluator command (signals only)
  --cmd CMD                    Optional verification command (runs each iteration)
  --model MODEL                Optional GPTDiff model override
  -h, --help                   Show help

EXAMPLES:
  /gptdiff-start --dir src \
    --goal "Improve code quality and add tests." \
    --max-iterations 5

  /gptdiff-start --dir src \
    --goal "Fix bugs and improve error handling." \
    --cmd "npm run build" \
    --max-iterations 3
HELP_EOF
}
TARGET_DIR=""
GOAL=""
MAX_ITERATIONS="3"
EVAL_CMD="null"
CMD="null"
MODEL="null"

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
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "   Try: /gptdiff-start --help" >&2
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

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: --max-iterations must be an integer (0 = unlimited), got: $MAX_ITERATIONS" >&2
  exit 1
fi

if ! python3 -c "import gptdiff" 2>/dev/null; then
  echo "❌ Error: 'gptdiff' Python package not found. Install with: pip install gptdiff" >&2
  exit 1
fi

mkdir -p .claude

yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  echo "$s"
}

TARGET_DIR_ESC="$(yaml_escape "$TARGET_DIR")"
GOAL_ESC="$(yaml_escape "$GOAL")"

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

cat > .claude/gptdiff-start.local.md <<EOF
---
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
target_dir: "$TARGET_DIR_ESC"
goal: "$GOAL_ESC"
eval_cmd: $EVAL_CMD_YAML
cmd: $CMD_YAML
model: $MODEL_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
 
GPTDiff loop is active.
 
Please reply with a short progress note (or just \`ok\`) and then stop.
To cancel: /gptdiff-stop
EOF

cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║                    🔁 GPTDIFF LOOP ACTIVATED                     ║
╚══════════════════════════════════════════════════════════════════╝

📁 Target:      $TARGET_DIR/
🎯 Goal:        $GOAL
🔄 Iterations:  $(if [[ "$MAX_ITERATIONS" -gt 0 ]]; then echo "1 of $MAX_ITERATIONS"; else echo "unlimited"; fi)
EOF

if [[ "$CMD_YAML" != "null" ]]; then
  echo "🔧 Verify cmd:  $CMD"
fi
if [[ "$EVAL_CMD_YAML" != "null" ]]; then
  echo "📊 Eval cmd:    $EVAL_CMD"
fi
if [[ "$MODEL_YAML" != "null" ]]; then
  echo "🤖 Model:       $MODEL"
fi

cat <<EOF

┌─────────────────────────────────────────────────────────────────┐
│  The loop will now run automatically via the Stop hook.        │
│  Each iteration: analyze → improve → verify → repeat           │
│                                                                 │
│  To cancel anytime:  /gptdiff-stop                       │
│  To check progress:  cat .claude/gptdiff-start.local.md          │
└─────────────────────────────────────────────────────────────────┘
EOF
