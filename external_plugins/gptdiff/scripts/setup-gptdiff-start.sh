#!/bin/bash

# GPTDiff Loop Setup Script
# Writes .claude/start/{slug}/state.local.md (state consumed by stop hook)
# Each loop has its own state file based on target hash, allowing multiple concurrent loops

set -euo pipefail

show_help() {
  cat << 'HELP_EOF'
GPTDiff Loop (Agent Loop)

USAGE:
  /start --dir PATH --goal "..." [OPTIONS]
  /start --file PATH --file PATH --goal "..." [OPTIONS]

OPTIONS:
  --dir PATH                   Target directory (can specify multiple)
  --file PATH                  Target file (can specify multiple)
  --goal TEXT                  Goal prompt for GPTDiff (required)
  --max-iterations N           Stop after N iterations (default: 3, 0 = unlimited)
  --inference-mode MODE        "claude" (default) or "external" LLM
  --eval-cmd CMD               Optional evaluator command (signals only)
  --feedback-cmd CMD           Run after each iteration, output feeds into next iteration
                               (e.g., screenshot tools, gameplay comparators, test runners)
  --feedback-image PATH        Image file to include in each iteration's context
                               (e.g., screenshot saved by feedback-cmd or external tool)
  --feedback-agent AGENT       Spawn a specialized agent to review changes each iteration
                               Use "auto" (Claude decides) or a custom description
                               (e.g., "security expert", "game balance reviewer")
  --model MODEL                Optional GPTDiff model override
  -h, --help                   Show help

FEEDBACK EXAMPLES:
  # Screenshot with image feedback (image is sent to LLM)
  /start --dir game/ui --goal "Improve UI aesthetics" \
    --feedback-cmd "screenshot-tool --output /tmp/ui.png" \
    --feedback-image /tmp/ui.png

  # Gameplay comparator with visual diff
  /start --dir game/enemies --goal "Balance enemy difficulty" \
    --feedback-cmd "python3 tools/run_simulation.py --screenshot /tmp/sim.png" \
    --feedback-image /tmp/sim.png

  # Test runner feedback (text only)
  /start --dir src --goal "Fix failing tests" \
    --feedback-cmd "npm test 2>&1 | tail -50"

  # Agent-based feedback (Claude decides what expert to spawn)
  /start --dir game/ui --goal "Improve UI aesthetics" \
    --feedback-agent auto

  # Custom agent description
  /start --dir game/enemies --goal "Balance enemy difficulty" \
    --feedback-agent "game balance expert"

EXAMPLES:
  /start --dir src \
    --goal "Improve code quality and add tests." \
    --max-iterations 5

  /start --dir src --dir lib \
    --goal "Refactor shared code between src and lib." \
    --max-iterations 3

  /start --file src/main.ts --file src/utils.ts \
    --goal "Optimize these specific files." \
    --max-iterations 3
HELP_EOF
}
TARGET_DIRS=()
TARGET_FILES=()
GOAL=""
MAX_ITERATIONS="3"
INFERENCE_MODE="claude"
EVAL_CMD="null"
FEEDBACK_CMD="null"
FEEDBACK_IMAGE="null"
FEEDBACK_AGENT="null"
MODEL="null"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --dir)
      TARGET_DIRS+=("${2:-}")
      shift 2
      ;;
    --file)
      TARGET_FILES+=("${2:-}")
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
    --inference-mode)
      INFERENCE_MODE="${2:-claude}"
      shift 2
      ;;
    --eval-cmd)
      EVAL_CMD="${2:-}"
      shift 2
      ;;
    --feedback-cmd)
      FEEDBACK_CMD="${2:-}"
      shift 2
      ;;
    --feedback-image)
      FEEDBACK_IMAGE="${2:-}"
      shift 2
      ;;
    --feedback-agent)
      FEEDBACK_AGENT="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "   Try: /start --help" >&2
      exit 1
      ;;
  esac
done

if [[ ${#TARGET_DIRS[@]} -eq 0 ]] && [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
  echo "❌ Error: At least one --dir or --file is required" >&2
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

# Validate directories exist
if [[ ${#TARGET_DIRS[@]} -gt 0 ]]; then
  for dir in "${TARGET_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
      echo "❌ Error: Directory does not exist: $dir" >&2
      exit 1
    fi
  done
fi

# Validate files exist
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  for file in "${TARGET_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "❌ Error: File does not exist: $file" >&2
      exit 1
    fi
  done
fi

mkdir -p .claude

# Compute loop slug FIRST (same algorithm as stop-hook.sh)
# This allows each loop to have its own state file
ALL_TARGETS_FOR_SLUG=""
if [[ ${#TARGET_DIRS[@]} -gt 0 ]]; then
  for dir in "${TARGET_DIRS[@]}"; do
    ALL_TARGETS_FOR_SLUG+="$dir"$'\n'
  done
fi
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  for file in "${TARGET_FILES[@]}"; do
    ALL_TARGETS_FOR_SLUG+="$file"$'\n'
  done
fi
LOOP_SLUG="$(echo "$ALL_TARGETS_FOR_SLUG" | md5sum | cut -c1-12)"
LOOP_DIR=".claude/start/$LOOP_SLUG"
mkdir -p "$LOOP_DIR"

yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  echo "$s"
}

GOAL_ESC="$(yaml_escape "$GOAL")"

if [[ -n "${EVAL_CMD:-}" ]] && [[ "$EVAL_CMD" != "null" ]]; then
  EVAL_CMD_ESC="$(yaml_escape "$EVAL_CMD")"
  EVAL_CMD_YAML="\"$EVAL_CMD_ESC\""
else
  EVAL_CMD_YAML="null"
fi

if [[ -n "${MODEL:-}" ]] && [[ "$MODEL" != "null" ]]; then
  MODEL_ESC="$(yaml_escape "$MODEL")"
  MODEL_YAML="\"$MODEL_ESC\""
else
  MODEL_YAML="null"
fi

if [[ -n "${FEEDBACK_CMD:-}" ]] && [[ "$FEEDBACK_CMD" != "null" ]]; then
  FEEDBACK_CMD_ESC="$(yaml_escape "$FEEDBACK_CMD")"
  FEEDBACK_CMD_YAML="\"$FEEDBACK_CMD_ESC\""
else
  FEEDBACK_CMD_YAML="null"
fi

if [[ -n "${FEEDBACK_IMAGE:-}" ]] && [[ "$FEEDBACK_IMAGE" != "null" ]]; then
  # Convert to absolute path
  FEEDBACK_IMAGE_ABS="$(cd "$(dirname "$FEEDBACK_IMAGE")" 2>/dev/null && pwd)/$(basename "$FEEDBACK_IMAGE")" || FEEDBACK_IMAGE_ABS="$FEEDBACK_IMAGE"
  FEEDBACK_IMAGE_ESC="$(yaml_escape "$FEEDBACK_IMAGE_ABS")"
  FEEDBACK_IMAGE_YAML="\"$FEEDBACK_IMAGE_ESC\""
else
  FEEDBACK_IMAGE_YAML="null"
fi

if [[ -n "${FEEDBACK_AGENT:-}" ]] && [[ "$FEEDBACK_AGENT" != "null" ]]; then
  FEEDBACK_AGENT_ESC="$(yaml_escape "$FEEDBACK_AGENT")"
  FEEDBACK_AGENT_YAML="\"$FEEDBACK_AGENT_ESC\""
else
  FEEDBACK_AGENT_YAML="null"
fi

# Build YAML arrays for dirs and files
build_yaml_array() {
  local arr=("$@")
  if [[ ${#arr[@]} -eq 0 ]]; then
    echo "[]"
  else
    echo ""
    for item in "${arr[@]}"; do
      local escaped="$(yaml_escape "$item")"
      echo "  - \"$escaped\""
    done
  fi
}

if [[ ${#TARGET_DIRS[@]} -gt 0 ]]; then
  TARGET_DIRS_YAML="$(build_yaml_array "${TARGET_DIRS[@]}")"
else
  TARGET_DIRS_YAML="[]"
fi
if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  TARGET_FILES_YAML="$(build_yaml_array "${TARGET_FILES[@]}")"
else
  TARGET_FILES_YAML="[]"
fi

# Generate a unique session ID to identify this Claude instance
# Store in a temp file keyed by git root so the stop hook can find it
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GIT_ROOT_HASH="$(echo "$GIT_ROOT" | md5sum | cut -c1-12)"
SESSION_FILE="/tmp/claude-gptdiff-session-$GIT_ROOT_HASH"

# Create or reuse session ID for this git repo
if [[ -f "$SESSION_FILE" ]]; then
  SESSION_ID="$(cat "$SESSION_FILE")"
else
  SESSION_ID="$(date +%s)-$(openssl rand -hex 4 2>/dev/null || echo $$)-$$"
  echo "$SESSION_ID" > "$SESSION_FILE"
fi

# Create state file
{
  echo "---"
  echo "active: true"
  echo "iteration: 1"
  echo "max_iterations: $MAX_ITERATIONS"
  echo "session_id: \"$SESSION_ID\""
  echo -n "target_dirs:"
  if [[ ${#TARGET_DIRS[@]} -eq 0 ]]; then
    echo " []"
  else
    echo ""
    for dir in "${TARGET_DIRS[@]}"; do
      echo "  - \"$(yaml_escape "$dir")\""
    done
  fi
  echo -n "target_files:"
  if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
    echo " []"
  else
    echo ""
    for file in "${TARGET_FILES[@]}"; do
      echo "  - \"$(yaml_escape "$file")\""
    done
  fi
  echo "goal: \"$GOAL_ESC\""
  echo "inference_mode: \"$INFERENCE_MODE\""
  echo "eval_cmd: $EVAL_CMD_YAML"
  echo "feedback_cmd: $FEEDBACK_CMD_YAML"
  echo "feedback_image: $FEEDBACK_IMAGE_YAML"
  echo "feedback_agent: $FEEDBACK_AGENT_YAML"
  echo "model: $MODEL_YAML"
  echo "started_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "---"
  echo " "
  echo "GPTDiff loop is active."
  echo " "
  echo "Please reply with a short progress note (or just \`ok\`) and then stop."
  echo "To cancel: /stop"
} > "$LOOP_DIR/state.local.md"

# Write lock file with session ID to claim ownership of this loop
# Other Claude instances will check this before processing the loop
echo "$SESSION_ID" > "$LOOP_DIR/.lock-owner"
echo "$(date +%s)" > "$LOOP_DIR/.last-activity"

cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║                    🔁 GPTDIFF LOOP ACTIVATED                     ║
╚══════════════════════════════════════════════════════════════════╝

EOF

# Show targets
if [[ ${#TARGET_DIRS[@]} -gt 0 ]]; then
  if [[ ${#TARGET_DIRS[@]} -eq 1 ]]; then
    echo "📁 Directory:   ${TARGET_DIRS[0]}/"
  else
    echo "📁 Directories:"
    for dir in "${TARGET_DIRS[@]}"; do
      echo "                - $dir/"
    done
  fi
fi

if [[ ${#TARGET_FILES[@]} -gt 0 ]]; then
  if [[ ${#TARGET_FILES[@]} -eq 1 ]]; then
    echo "📄 File:        ${TARGET_FILES[0]}"
  else
    echo "📄 Files:"
    for file in "${TARGET_FILES[@]}"; do
      echo "                - $file"
    done
  fi
fi

echo "🎯 Goal:        $GOAL"
echo "🔄 Iterations:  $(if [[ "$MAX_ITERATIONS" -gt 0 ]]; then echo "1 of $MAX_ITERATIONS"; else echo "unlimited"; fi)"
echo "🧠 Inference:   $(if [[ "$INFERENCE_MODE" == "external" ]]; then echo "External LLM (gptdiff)"; else echo "Claude Code"; fi)"

if [[ "$EVAL_CMD_YAML" != "null" ]]; then
  echo "📊 Eval cmd:    $EVAL_CMD"
fi
if [[ "$FEEDBACK_CMD_YAML" != "null" ]]; then
  echo "📸 Feedback:    $FEEDBACK_CMD"
fi
if [[ "$FEEDBACK_IMAGE_YAML" != "null" ]]; then
  echo "🖼️  Image:       $FEEDBACK_IMAGE"
fi
if [[ "$FEEDBACK_AGENT_YAML" != "null" ]]; then
  echo "🧑‍💼 Agent:       $FEEDBACK_AGENT"
fi
if [[ "$MODEL_YAML" != "null" ]]; then
  echo "🤖 Model:       $MODEL"
fi

# Use the already-computed slug
echo "📝 Logs:        $LOOP_DIR/"

cat <<EOF

┌─────────────────────────────────────────────────────────────────┐
│  The loop will now run automatically via the Stop hook.        │
│  Each iteration: analyze → improve → verify → repeat           │
│                                                                 │
│  To cancel anytime:  /stop                                      │
│  To check progress:  /status                                    │
└─────────────────────────────────────────────────────────────────┘
EOF
