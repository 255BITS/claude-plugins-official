#!/bin/bash

# GPTDiff Stop Hook
#
# Implements an in-session agent loop that:
#   - runs optional eval command (signals/metrics)
#   - runs optional verification command (for feedback, does not gate)
#   - makes improvements via LLM (external or Claude Code)
#
# The loop is activated by /start which creates:
#   .claude/start.local.md
#
# Inference mode:
#   - If GPTDIFF_LLM_API_KEY is set: uses external LLM via gptdiff Python API
#   - Otherwise: uses Claude Code's own inference (no API key needed)

set -euo pipefail

# Consume hook input (Stop hook API provides JSON on stdin)
_HOOK_INPUT="$(cat || true)"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_FILE="$ROOT_DIR/.claude/start.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  # No active loop - allow normal stop
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  GPTDiff loop: 'jq' is required for stop hook JSON responses. Stopping loop." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Check that Python and gptdiff package are available (for file loading utilities)
if ! python3 -c "import gptdiff" 2>/dev/null; then
  echo "⚠️  GPTDiff loop: 'gptdiff' Python package not found. Install with: pip install gptdiff" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Get the plugin hooks directory
PLUGIN_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse YAML frontmatter (YAML between --- markers)
FRONTMATTER="$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")"

yaml_get_raw() {
  local key="$1"
  echo "$FRONTMATTER" | sed -n "s/^${key}:[[:space:]]*//p" | head -n 1
}

strip_yaml_quotes() {
  local v="$1"
  echo "$v" | sed 's/^"\(.*\)"$/\1/'
}

yaml_unescape() {
  local v="$1"
  v="${v//\\\\/\\}"
  v="${v//\\\"/\"}"
  echo "$v"
}

# Parse YAML array (returns newline-separated values)
yaml_get_array() {
  local key="$1"
  local in_array=false
  local found_key=false
  echo "$FRONTMATTER" | while IFS= read -r line; do
    if [[ "$line" =~ ^${key}:[[:space:]]*$ ]]; then
      found_key=true
      in_array=true
      continue
    elif [[ "$line" =~ ^${key}:[[:space:]]*\[\] ]]; then
      # Empty array
      break
    elif [[ "$found_key" == "true" && "$in_array" == "true" ]]; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
        local val="${BASH_REMATCH[1]}"
        # Strip quotes
        val="$(echo "$val" | sed 's/^"\(.*\)"$/\1/')"
        # Unescape
        val="${val//\\\\/\\}"
        val="${val//\\\"/\"}"
        echo "$val"
      elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
        # New key, end of array
        break
      fi
    fi
  done
}

ITERATION="$(strip_yaml_quotes "$(yaml_get_raw iteration)")"
MAX_ITERATIONS="$(strip_yaml_quotes "$(yaml_get_raw max_iterations)")"
GOAL="$(yaml_unescape "$(strip_yaml_quotes "$(yaml_get_raw goal)")")"
EVAL_CMD_RAW="$(yaml_get_raw eval_cmd)"
MODEL_RAW="$(yaml_get_raw model)"
INFERENCE_MODE_RAW="$(yaml_get_raw inference_mode)"

# Parse arrays for multiple targets
TARGET_DIRS_STR="$(yaml_get_array target_dirs)"
TARGET_FILES_STR="$(yaml_get_array target_files)"

# Also support legacy single target_dir
LEGACY_TARGET_DIR="$(yaml_unescape "$(strip_yaml_quotes "$(yaml_get_raw target_dir)")")"
if [[ -n "$LEGACY_TARGET_DIR" ]] && [[ -z "$TARGET_DIRS_STR" ]]; then
  TARGET_DIRS_STR="$LEGACY_TARGET_DIR"
fi

EVAL_CMD="$(yaml_unescape "$(strip_yaml_quotes "$EVAL_CMD_RAW")")"
MODEL="$(yaml_unescape "$(strip_yaml_quotes "$MODEL_RAW")")"
INFERENCE_MODE="$(yaml_unescape "$(strip_yaml_quotes "$INFERENCE_MODE_RAW")")"

# Normalize null-like values
if [[ "${EVAL_CMD_RAW:-}" == "null" ]] || [[ -z "${EVAL_CMD:-}" ]]; then EVAL_CMD=""; fi
if [[ "${MODEL_RAW:-}" == "null" ]] || [[ -z "${MODEL:-}" ]]; then MODEL=""; fi
if [[ "${INFERENCE_MODE_RAW:-}" == "null" ]] || [[ -z "${INFERENCE_MODE:-}" ]]; then INFERENCE_MODE="claude"; fi

# Validate numeric fields
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  GPTDiff loop: State file corrupted (iteration is not a number)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  GPTDiff loop: State file corrupted (max_iterations is not a number)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

if [[ -z "${TARGET_DIRS_STR:-}" ]] && [[ -z "${TARGET_FILES_STR:-}" ]]; then
  echo "⚠️  GPTDiff loop: State file corrupted (no target_dirs or target_files)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Validate all target directories exist
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  TARGET_ABS="$ROOT_DIR/$dir"
  if [[ ! -d "$TARGET_ABS" ]]; then
    echo "⚠️  GPTDiff loop: target directory does not exist: $TARGET_ABS" >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
done <<< "$TARGET_DIRS_STR"

# Validate all target files exist
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  TARGET_ABS="$ROOT_DIR/$file"
  if [[ ! -f "$TARGET_ABS" ]]; then
    echo "⚠️  GPTDiff loop: target file does not exist: $TARGET_ABS" >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
done <<< "$TARGET_FILES_STR"

# Build a display string for targets
TARGETS_DISPLAY=""
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  TARGETS_DISPLAY+="$dir/ "
done <<< "$TARGET_DIRS_STR"
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  TARGETS_DISPLAY+="$file "
done <<< "$TARGET_FILES_STR"
TARGETS_DISPLAY="${TARGETS_DISPLAY% }"  # Trim trailing space

# Create a slug for the loop directory (hash of all targets)
TARGET_SLUG="$(echo "$TARGET_DIRS_STR$TARGET_FILES_STR" | md5sum | cut -c1-12)"

# Stop if max iterations exceeded (0 = unlimited)
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -gt $MAX_ITERATIONS ]]; then
  echo "🛑 GPTDiff loop: Max iterations ($MAX_ITERATIONS) reached." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Extract base prompt (everything after the closing ---)
BASE_PROMPT="$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")"
if [[ -z "$BASE_PROMPT" ]]; then
  BASE_PROMPT="Continue the GPTDiff loop. Reply with a short progress note, then stop."
fi

# Logs are kept per target set (TARGET_SLUG was already computed above)
LOOP_DIR="$ROOT_DIR/.claude/start/$TARGET_SLUG"
mkdir -p "$LOOP_DIR"

EVAL_LOG="$LOOP_DIR/eval.log"
GPTDIFF_LOG="$LOOP_DIR/gptdiff.log"
DIFFSTAT_FILE="$LOOP_DIR/diffstat.txt"
CHANGED_FILES_FILE="$LOOP_DIR/changed-files.txt"
STATUS_FILE="$LOOP_DIR/status.txt"

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

append_header() {
  local f="$1"
  local title="$2"
  {
    echo "============================================================"
    echo "$title"
    echo "UTC: $(utc_now)"
    echo "Iteration: $ITERATION"
    echo "Targets: $TARGETS_DISPLAY"
    echo "============================================================"
  } >> "$f"
}

# Optional evaluator (non-gating)
EVAL_EXIT=0
if [[ -n "$EVAL_CMD" ]]; then
  append_header "$EVAL_LOG" "EVAL"
  set +e
  (
    cd "$ROOT_DIR" || exit 127
    GPTDIFF_LOOP_TARGETS="$TARGETS_DISPLAY" bash -lc "$EVAL_CMD"
  ) >> "$EVAL_LOG" 2>&1
  EVAL_EXIT=$?
  set -e
  echo "" >> "$EVAL_LOG"
fi

# Build the goal prompt with eval signals
EVAL_TAIL=""
if [[ -f "$EVAL_LOG" ]]; then
  EVAL_TAIL="$(tail -n 80 "$EVAL_LOG" | sed 's/\r$//')"
fi

# Get list of files in target directories/files (using gptdiff's .gptignore-aware loader)
FILE_LIST=""
set +e
# Build arguments for prepare_context.py
PREPARE_ARGS=""
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  PREPARE_ARGS+=" --dir \"$ROOT_DIR/$dir\""
done <<< "$TARGET_DIRS_STR"
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  PREPARE_ARGS+=" --file \"$ROOT_DIR/$file\""
done <<< "$TARGET_FILES_STR"
FILE_LIST="$(eval python3 "$PLUGIN_HOOKS_DIR/prepare_context.py" $PREPARE_ARGS --list-only 2>/dev/null)"
set -e

# Determine inference mode: external LLM or Claude Code
# Respect the saved inference_mode from state file (set during /start)
USE_EXTERNAL_LLM="false"
if [[ "$INFERENCE_MODE" == "external" ]]; then
  if [[ -n "${GPTDIFF_LLM_API_KEY:-}" ]]; then
    USE_EXTERNAL_LLM="true"
  else
    echo "⚠️  GPTDiff loop: External LLM mode requested but GPTDIFF_LLM_API_KEY not set. Falling back to Claude Code." >&2
  fi
fi

# Build the goal prompt for the LLM (used by both modes)
GPTDIFF_GOAL="Iteration: $ITERATION / $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
Targets: $TARGETS_DISPLAY

GOAL:
$GOAL

CONSTRAINTS:
- Make one coherent, meaningful improvement per iteration (small, reviewable diffs).
- Preserve existing intent and structure; avoid unnecessary rewrites.
- Keep changes focused and reviewable.
- ONLY modify files within the specified targets.

SIGNALS (optional):
--- eval (tail) ---
$EVAL_TAIL
"

# Run the appropriate inference mode
GPTDIFF_EXIT=0
if [[ "$USE_EXTERNAL_LLM" == "true" ]]; then
  # External LLM mode: use gptdiff Python API
  append_header "$GPTDIFF_LOG" "GPTDIFF_EXTERNAL_LLM"
  {
    echo "Mode: External LLM (GPTDIFF_LLM_API_KEY set)"
    echo "Model: ${MODEL:-${GPTDIFF_MODEL:-default}}"
    echo ""
    echo "Goal prompt:"
    echo "$GPTDIFF_GOAL"
    echo ""
    echo "----- gptdiff output -----"
  } >> "$GPTDIFF_LOG"

  # Run gptdiff in background to avoid hook timeout
  PENDING_FILE="$LOOP_DIR/pending"
  RESULT_FILE="$LOOP_DIR/result"

  # Check if previous background job is still running
  if [[ -f "$PENDING_FILE" ]]; then
    PID=$(cat "$PENDING_FILE" 2>/dev/null)
    if kill -0 "$PID" 2>/dev/null; then
      echo "⏳ External LLM still processing (PID $PID)..." >&2
      # Return without blocking - will check again on next stop
      GPTDIFF_EXIT=0
    else
      # Previous job finished, check result
      if [[ -f "$RESULT_FILE" ]]; then
        GPTDIFF_EXIT=$(cat "$RESULT_FILE")
        echo "✅ External LLM completed (exit: $GPTDIFF_EXIT)" >&2
      else
        GPTDIFF_EXIT=1
        echo "⚠️ External LLM job finished but no result found" >&2
      fi
      rm -f "$PENDING_FILE" "$RESULT_FILE"
    fi
  else
    # Start new background job
    echo "🚀 Starting external LLM in background..." >&2

    # Build gptdiff_apply.py arguments for multiple targets
    APPLY_ARGS="--verbose"
    if [[ -n "$MODEL" ]]; then
      APPLY_ARGS+=" --model \"$MODEL\""
    fi
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue
      APPLY_ARGS+=" --dir \"$ROOT_DIR/$dir\""
    done <<< "$TARGET_DIRS_STR"
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      APPLY_ARGS+=" --file \"$ROOT_DIR/$file\""
    done <<< "$TARGET_FILES_STR"

    (
      cd "$ROOT_DIR" || exit 127
      eval python3 "$PLUGIN_HOOKS_DIR/gptdiff_apply.py" $APPLY_ARGS "\"$GPTDIFF_GOAL\"" >> "$GPTDIFF_LOG" 2>&1
      echo $? > "$RESULT_FILE"
      rm -f "$PENDING_FILE"
    ) &
    BACKGROUND_PID=$!
    echo "$BACKGROUND_PID" > "$PENDING_FILE"
    echo "   PID: $BACKGROUND_PID - check /status or wait for next iteration" >&2
    GPTDIFF_EXIT=0
  fi
else
  # Claude Code mode: just log, prompt will be returned to Claude Code
  append_header "$GPTDIFF_LOG" "CLAUDE_CODE_INFERENCE"
  {
    echo "Mode: Claude Code inference (no GPTDIFF_LLM_API_KEY)"
    echo "Iteration: $ITERATION"
    echo "Goal: $GOAL"
    echo "Files in scope:"
    echo "$FILE_LIST"
    echo ""
  } >> "$GPTDIFF_LOG"
fi

# Write a small diffstat snapshot so the loop is visible
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" diff --stat > "$DIFFSTAT_FILE" 2>/dev/null || true
  git -C "$ROOT_DIR" diff --name-only > "$CHANGED_FILES_FILE" 2>/dev/null || true
  git -C "$ROOT_DIR" status --porcelain > "$STATUS_FILE" 2>/dev/null || true
else
  echo "(not a git repo)" > "$DIFFSTAT_FILE"
  echo "(not a git repo)" > "$CHANGED_FILES_FILE"
  echo "(not a git repo)" > "$STATUS_FILE"
fi

# Bump iteration in state file
NEXT_ITERATION=$((ITERATION + 1))
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Build progress indicator
if [[ $MAX_ITERATIONS -gt 0 ]]; then
  REMAINING=$((MAX_ITERATIONS - ITERATION))
  PROGRESS_BAR=""
  for ((i=1; i<=MAX_ITERATIONS && i<=10; i++)); do
    if [[ $i -le $ITERATION ]]; then
      PROGRESS_BAR+="●"
    else
      PROGRESS_BAR+="○"
    fi
  done
  if [[ $MAX_ITERATIONS -gt 10 ]]; then
    PROGRESS_BAR+="..."
  fi
  ITER_INFO="[$ITERATION/$MAX_ITERATIONS] $PROGRESS_BAR ($REMAINING remaining)"
else
  ITER_INFO="[$ITERATION/∞]"
fi

# If next iteration would exceed max, stop on next stop attempt
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $NEXT_ITERATION -gt $MAX_ITERATIONS ]]; then
  SYSTEM_MSG="🛑 GPTDiff FINAL ITERATION $ITER_INFO - Loop complete after this. Review: git diff"
else
  if [[ "$USE_EXTERNAL_LLM" == "true" ]]; then
    SYSTEM_MSG="🔁 GPTDiff $ITER_INFO | $TARGETS_DISPLAY | External LLM | /stop to stop"
  else
    SYSTEM_MSG="🔁 GPTDiff $ITER_INFO | $TARGETS_DISPLAY | Claude Code | /stop to stop"
  fi
fi

CHANGED_FILES_PREVIEW="$(tail -n 40 "$CHANGED_FILES_FILE" 2>/dev/null || true)"
DIFFSTAT_PREVIEW="$(tail -n 80 "$DIFFSTAT_FILE" 2>/dev/null || true)"

# Build the prompt based on inference mode
if [[ "$USE_EXTERNAL_LLM" == "true" ]]; then
  # External LLM mode: gptdiff already made changes, just summarize
  REASON_PROMPT="$BASE_PROMPT

╔══════════════════════════════════════════════════════════════════╗
║  🔁 GPTDIFF LOOP - ITERATION $ITERATION of $(printf "%-3s" "$(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "∞"; fi)")                          ║
╚══════════════════════════════════════════════════════════════════╝

**Mode:** External LLM (gptdiff)
**Targets:** \`$TARGETS_DISPLAY\`
**Progress:** $ITER_INFO
**gptdiff exit:** $GPTDIFF_EXIT
**eval exit:** $EVAL_EXIT

### Changed files
\`\`\`
$CHANGED_FILES_PREVIEW
\`\`\`

### Diffstat
\`\`\`
$DIFFSTAT_PREVIEW
\`\`\`

---

**Reply with 1-5 bullets: what changed + what to improve next, then stop.**"
else
  # Claude Code mode: ask Claude Code to make the improvements
  REASON_PROMPT="
╔══════════════════════════════════════════════════════════════════╗
║  🔁 GPTDIFF LOOP - ITERATION $ITERATION of $(printf "%-3s" "$(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "∞"; fi)")                          ║
╚══════════════════════════════════════════════════════════════════╝

You are running an iterative improvement loop.

### Task
**Targets:** \`$TARGETS_DISPLAY\`
**Progress:** $ITER_INFO

### Goal
$GOAL

### Instructions
1. **Read** the files listed below
2. **ONLY modify files in the specified targets** - do NOT edit files outside these paths
3. **Make ONE coherent improvement** - keep changes small and reviewable
4. **Use Edit tool** to apply your changes directly to the files
5. **Preserve** existing structure and intent; avoid unnecessary rewrites

### Files in scope (respecting .gptignore)
\`\`\`
$FILE_LIST
\`\`\`

### Signals from evaluators
$(if [[ -n "$EVAL_TAIL" ]]; then echo "**Eval output (tail):**"; echo '```'; echo "$EVAL_TAIL"; echo '```'; else echo "_No eval command configured_"; fi)

### Recent changes
$(if [[ -n "$CHANGED_FILES_PREVIEW" ]]; then echo '```'; echo "$CHANGED_FILES_PREVIEW"; echo '```'; else echo "_No changes yet_"; fi)

---

**Now read the files, make ONE improvement, then reply with a brief summary of what you changed.**"
fi

# Block stop and feed prompt back
jq -n \
  --arg prompt "$REASON_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'
