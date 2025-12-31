#!/bin/bash

# GPTDiff Stop Hook
#
# Implements an in-session agent loop that:
#   - runs optional eval command (signals/metrics)
#   - runs optional verification command (for feedback, does not gate)
#   - makes improvements via LLM (external or Claude Code)
#
# The loop is activated by /start which creates:
#   .claude/start/{slug}/state.local.md
#
# Multiple loops can run concurrently (each with different targets)
#
# Inference mode:
#   - If GPTDIFF_LLM_API_KEY is set: uses external LLM via gptdiff Python API
#   - Otherwise: uses Claude Code's own inference (no API key needed)

set -euo pipefail

# Consume hook input (Stop hook API provides JSON on stdin)
_HOOK_INPUT="$(cat || true)"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Find all active loop state files
# Each loop has its own state file: .claude/start/{slug}/state.local.md
LOOP_STATE_DIR="$ROOT_DIR/.claude/start"
STATE_FILES=()
if [[ -d "$LOOP_STATE_DIR" ]]; then
  while IFS= read -r -d '' state_file; do
    STATE_FILES+=("$state_file")
  done < <(find "$LOOP_STATE_DIR" -name "state.local.md" -print0 2>/dev/null)
fi

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
  # No active loops - allow normal stop
  exit 0
fi

# For now, process the first active loop found
# TODO: Could combine multiple loops into a single prompt
STATE_FILE="${STATE_FILES[0]}"

# If multiple loops are active, warn the user
if [[ ${#STATE_FILES[@]} -gt 1 ]]; then
  echo "⚠️  Multiple GPTDiff loops active (${#STATE_FILES[@]} loops). Processing first one." >&2
  echo "   Active loops:" >&2
  for sf in "${STATE_FILES[@]}"; do
    echo "   - $(dirname "$sf" | xargs basename)" >&2
  done
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
FEEDBACK_CMD_RAW="$(yaml_get_raw feedback_cmd)"
FEEDBACK_IMAGE_RAW="$(yaml_get_raw feedback_image)"
FEEDBACK_AGENT_RAW="$(yaml_get_raw feedback_agent)"
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
FEEDBACK_CMD="$(yaml_unescape "$(strip_yaml_quotes "$FEEDBACK_CMD_RAW")")"
FEEDBACK_IMAGE="$(yaml_unescape "$(strip_yaml_quotes "$FEEDBACK_IMAGE_RAW")")"
FEEDBACK_AGENT="$(yaml_unescape "$(strip_yaml_quotes "$FEEDBACK_AGENT_RAW")")"
MODEL="$(yaml_unescape "$(strip_yaml_quotes "$MODEL_RAW")")"
INFERENCE_MODE="$(yaml_unescape "$(strip_yaml_quotes "$INFERENCE_MODE_RAW")")"

# Normalize null-like values
if [[ "${EVAL_CMD_RAW:-}" == "null" ]] || [[ -z "${EVAL_CMD:-}" ]]; then EVAL_CMD=""; fi
if [[ "${FEEDBACK_CMD_RAW:-}" == "null" ]] || [[ -z "${FEEDBACK_CMD:-}" ]]; then FEEDBACK_CMD=""; fi
if [[ "${FEEDBACK_IMAGE_RAW:-}" == "null" ]] || [[ -z "${FEEDBACK_IMAGE:-}" ]]; then FEEDBACK_IMAGE=""; fi
if [[ "${FEEDBACK_AGENT_RAW:-}" == "null" ]] || [[ -z "${FEEDBACK_AGENT:-}" ]]; then FEEDBACK_AGENT=""; fi
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

# Loop directory is the parent of the state file
# (state file is at .claude/start/{slug}/state.local.md)
LOOP_DIR="$(dirname "$STATE_FILE")"
TARGET_SLUG="$(basename "$LOOP_DIR")"

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

# LOOP_DIR was already set above from the state file's parent directory
mkdir -p "$LOOP_DIR"

EVAL_LOG="$LOOP_DIR/eval.log"
FEEDBACK_LOG="$LOOP_DIR/feedback.log"
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

# Get feedback from PREVIOUS iteration (if any)
# Feedback runs AFTER changes are made, so this is from the last iteration
FEEDBACK_TAIL=""
if [[ -f "$FEEDBACK_LOG" ]]; then
  FEEDBACK_TAIL="$(tail -n 100 "$FEEDBACK_LOG" | sed 's/\r$//')"
fi

# Get agent feedback from PREVIOUS iteration (if any)
# Include ALL agent feedback - it's valuable context even if long
AGENT_FEEDBACK_FILE="$LOOP_DIR/agent-feedback.txt"
AGENT_FEEDBACK_CONTENT=""
if [[ -f "$AGENT_FEEDBACK_FILE" ]]; then
  AGENT_FEEDBACK_CONTENT="$(cat "$AGENT_FEEDBACK_FILE" | sed 's/\r$//')"
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

$(if [[ -n "$FEEDBACK_TAIL" ]]; then echo "--- feedback from previous iteration ---"; echo "$FEEDBACK_TAIL"; fi)
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
  EXTERNAL_LLM_PENDING="false"

  # Check if previous background job is still running
  if [[ -f "$PENDING_FILE" ]]; then
    PID=$(cat "$PENDING_FILE" 2>/dev/null)
    if kill -0 "$PID" 2>/dev/null; then
      echo "⏳ External LLM still processing (PID $PID)..." >&2
      EXTERNAL_LLM_PENDING="true"
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
    # Add feedback images - both explicit and auto-detected
    if [[ -n "$FEEDBACK_IMAGE" ]] && [[ -f "$FEEDBACK_IMAGE" ]]; then
      APPLY_ARGS+=" --image \"$FEEDBACK_IMAGE\""
    fi
    # Auto-detect Claude-saved feedback images
    for ext in png jpg jpeg gif webp; do
      AUTO_IMAGE="$LOOP_DIR/feedback-image.$ext"
      if [[ -f "$AUTO_IMAGE" ]] && [[ "$AUTO_IMAGE" != "$FEEDBACK_IMAGE" ]]; then
        APPLY_ARGS+=" --image \"$AUTO_IMAGE\""
      fi
    done
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
    EXTERNAL_LLM_PENDING="true"
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

# Run feedback command (after changes are made, for next iteration)
# This captures external feedback like screenshots, test results, simulations
FEEDBACK_EXIT=0
FEEDBACK_JUST_RAN="false"
if [[ -n "$FEEDBACK_CMD" ]] && [[ "${EXTERNAL_LLM_PENDING:-false}" != "true" ]]; then
  append_header "$FEEDBACK_LOG" "FEEDBACK (iteration $ITERATION)"
  set +e
  (
    cd "$ROOT_DIR" || exit 127
    GPTDIFF_LOOP_TARGETS="$TARGETS_DISPLAY" \
    GPTDIFF_LOOP_ITERATION="$ITERATION" \
    GPTDIFF_LOOP_GOAL="$GOAL" \
    bash -lc "$FEEDBACK_CMD"
  ) >> "$FEEDBACK_LOG" 2>&1
  FEEDBACK_EXIT=$?
  set -e
  echo "" >> "$FEEDBACK_LOG"
  echo "Exit code: $FEEDBACK_EXIT" >> "$FEEDBACK_LOG"
  echo "" >> "$FEEDBACK_LOG"
  FEEDBACK_JUST_RAN="true"
fi

# Bump iteration in state file (only if not waiting for external LLM)
if [[ "${EXTERNAL_LLM_PENDING:-false}" != "true" ]]; then
  NEXT_ITERATION=$((ITERATION + 1))
  TEMP_FILE="${STATE_FILE}.tmp.$$"
  sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"
else
  NEXT_ITERATION=$ITERATION
fi

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
if [[ "$USE_EXTERNAL_LLM" == "true" ]] && [[ "${EXTERNAL_LLM_PENDING:-false}" == "true" ]]; then
  # External LLM is still processing - ask Claude to wait
  REASON_PROMPT="
╔══════════════════════════════════════════════════════════════════╗
║  ⏳ GPTDIFF LOOP - WAITING FOR EXTERNAL LLM                      ║
╚══════════════════════════════════════════════════════════════════╝

**Mode:** External LLM (gptdiff)
**Targets:** \`$TARGETS_DISPLAY\`
**Progress:** $ITER_INFO (iteration not advanced while waiting)

The external LLM is still processing. This can take a few minutes.

You can:
- **Wait** and reply with 'ok' to check again
- **Check logs**: \`tail -50 $GPTDIFF_LOG\`
- **Cancel**: \`/stop\` to end the loop

---

**Reply with 'ok' to check if the external LLM has finished.**"
elif [[ "$USE_EXTERNAL_LLM" == "true" ]]; then
  # External LLM mode: gptdiff already made changes, review and act
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

### Your role
The external LLM made the changes above. You may now:
- **Review** the changes (use \`git diff\` to inspect)
- **Run commands** based on the current state:
  - Commit changes: \`git add . && git commit -m \"...\"\`
  - Run tests or linters to verify
  - Any other maintenance commands
- **Summarize** what changed and what to improve next

---

**Review the changes, run any appropriate commands, then reply with a brief summary.**"
else
  # Claude Code mode: ask Claude Code to make the improvements
  # Claude Code can explore the codebase itself - no need to constrain to specific files

  # Get fresh feedback output if it just ran
  FRESH_FEEDBACK=""
  if [[ "$FEEDBACK_JUST_RAN" == "true" ]] && [[ -f "$FEEDBACK_LOG" ]]; then
    FRESH_FEEDBACK="$(tail -n 100 "$FEEDBACK_LOG" | sed 's/\r$//')"
  fi

  # Build feedback section for prompt
  FEEDBACK_SECTION=""
  if [[ -n "$FRESH_FEEDBACK" ]]; then
    FEEDBACK_SECTION="### 📸 Feedback from this iteration
\`\`\`
$FRESH_FEEDBACK
\`\`\`

"
  elif [[ -n "$FEEDBACK_TAIL" ]]; then
    FEEDBACK_SECTION="### 📸 Feedback from previous iteration
\`\`\`
$FEEDBACK_TAIL
\`\`\`

"
  fi

  # Add agent feedback if present (include ALL of it - valuable context)
  if [[ -n "$AGENT_FEEDBACK_CONTENT" ]]; then
    FEEDBACK_SECTION+="### 🧑‍💼 Expert Agent Feedback (from previous iteration)
\`\`\`
$AGENT_FEEDBACK_CONTENT
\`\`\`

"
  fi

  # Build image section - check both explicit --feedback-image AND auto-detected Claude-saved images
  IMAGE_SECTION=""
  ALL_FEEDBACK_IMAGES=()

  # Add explicit feedback image if set
  if [[ -n "$FEEDBACK_IMAGE" ]] && [[ -f "$FEEDBACK_IMAGE" ]]; then
    ALL_FEEDBACK_IMAGES+=("$FEEDBACK_IMAGE")
  fi

  # Auto-detect Claude-saved feedback images in the loop directory
  # Convention: Claude can save images to .claude/start/<slug>/feedback-image.{png,jpg,jpeg,gif,webp}
  for ext in png jpg jpeg gif webp; do
    AUTO_IMAGE="$LOOP_DIR/feedback-image.$ext"
    if [[ -f "$AUTO_IMAGE" ]]; then
      # Avoid duplicates
      if [[ ! " ${ALL_FEEDBACK_IMAGES[*]} " =~ " ${AUTO_IMAGE} " ]]; then
        ALL_FEEDBACK_IMAGES+=("$AUTO_IMAGE")
      fi
    fi
  done

  # Build image section from all found images
  if [[ ${#ALL_FEEDBACK_IMAGES[@]} -gt 0 ]]; then
    IMAGE_SECTION="### 🖼️ Visual Feedback
**IMPORTANT:** Read the image file(s) to see the current state:
"
    for img in "${ALL_FEEDBACK_IMAGES[@]}"; do
      IMAGE_SECTION+="\`\`\`
$img
\`\`\`
"
    done
    IMAGE_SECTION+="Use your Read tool on these image files to view them before making changes.

"
  fi

  # Build exploration instruction - always encourage feedback gathering
  # Tell Claude about the image save convention
  EXPLORATION_INSTRUCTION="5. **Gather feedback** - After making changes, run tools to evaluate progress:
   - Take screenshots if working on UI/visual elements
   - Run simulations or tests if working on logic
   - Execute test suites to verify correctness
   - **To persist images for next iteration**: Save to \`$LOOP_DIR/feedback-image.png\`
     (The loop will automatically include this image in the next iteration)"

  # Build agent feedback instruction if feedback_agent is set
  AGENT_INSTRUCTION=""
  AGENTS_CATALOG=""

  # If feedback_agent is "auto" or any custom value, enable agent feedback
  if [[ -n "$FEEDBACK_AGENT" ]]; then
    if [[ "$ITERATION" -eq 1 ]]; then
      # ITERATION 1: Spawn agent FIRST to analyze initial state and guide first improvement
      if [[ "$FEEDBACK_AGENT" == "auto" ]]; then
        AGENT_INSTRUCTION="
### ⚠️ ITERATION 1: Spawn expert agent FIRST

**BEFORE making any changes**, you MUST spawn an agent to analyze the initial state.

1. Check your available agents (Task tool)
2. Pick the one best suited for the goal
3. Spawn it with this prompt:

   \`\`\`
   Analyze the initial state of: $TARGETS_DISPLAY
   Goal: $GOAL

   This is iteration 1 - no changes have been made yet.
   Review the current code and provide:
   1. Assessment of current state
   2. Priority areas to improve
   3. Specific first improvement to make
   4. What to watch out for

   Write your analysis to: $LOOP_DIR/agent-feedback.txt
   \`\`\`

4. **WAIT for the agent's response**
5. **Output the agent's feedback** so the user can see it
6. **THEN** make ONE improvement based on the agent's guidance

Do NOT skip the agent step. Do NOT make changes before the agent analyzes."
      else
        AGENT_INSTRUCTION="
### ⚠️ ITERATION 1: Spawn expert agent FIRST

**BEFORE making any changes**, spawn \`$FEEDBACK_AGENT\` to analyze the initial state.

Use Task tool with \`subagent_type: \"$FEEDBACK_AGENT\"\`

Prompt:
\`\`\`
Analyze the initial state of: $TARGETS_DISPLAY
Goal: $GOAL

This is iteration 1 - no changes have been made yet.
Review the current code and provide:
1. Assessment of current state
2. Priority areas to improve
3. Specific first improvement to make
4. What to watch out for

Write your analysis to: $LOOP_DIR/agent-feedback.txt
\`\`\`

**WAIT for the agent's response.**
**Output the agent's feedback** so the user can see it.
**THEN** make ONE improvement based on their guidance.

Do NOT skip the agent step. Do NOT make changes before the agent analyzes."
      fi
    else
      # ITERATIONS 2+: Make improvement, then spawn agent for feedback
      if [[ "$FEEDBACK_AGENT" == "auto" ]]; then
        AGENT_INSTRUCTION="
6. **REQUIRED: Spawn expert agent** - After making your improvement, spawn a feedback agent.

   **How to invoke:**
   1. Check your available agents (Task tool)
   2. Pick the agent best suited for the NEXT subgoal toward the goal
   3. Use the Task tool with that agent's name as \`subagent_type\`
   4. In your prompt, provide context:
      - Files to review: \`$TARGETS_DISPLAY\`
      - Overall goal: $GOAL
      - Request specific, actionable feedback for the next iteration
      - Write feedback to: \`$LOOP_DIR/agent-feedback.txt\`

   If no specialized agent fits, use \`general-purpose\` with a detailed prompt.

   **Output the agent's feedback** so the user can see it. Do NOT skip this step."
      else
        AGENT_INSTRUCTION="
6. **REQUIRED: Spawn expert agent** - After making your improvement, spawn \`$FEEDBACK_AGENT\`.

   Use the Task tool with \`subagent_type: \"$FEEDBACK_AGENT\"\`

   In your prompt, provide:
   - Files to review: \`$TARGETS_DISPLAY\`
   - Overall goal: $GOAL
   - Request specific, actionable feedback for the next iteration
   - Write feedback to: \`$LOOP_DIR/agent-feedback.txt\`

   **Output the agent's feedback** so the user can see it. Do NOT skip this step."
      fi
    fi
  fi

  REASON_PROMPT="
╔══════════════════════════════════════════════════════════════════╗
║  🔁 GPTDIFF LOOP - ITERATION $ITERATION of $(printf "%-3s" "$(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "∞"; fi)")                          ║
╚══════════════════════════════════════════════════════════════════╝

You are running an iterative improvement loop.

### Goal
$GOAL

### Progress
$ITER_INFO

### Instructions
1. **Explore** the codebase to find relevant files
2. **Make ONE coherent improvement** - keep changes small and reviewable
3. **Preserve** existing structure and intent; avoid unnecessary rewrites
4. **Run commands** as needed:
   - Commit changes: \`git add . && git commit -m \"...\"\`
   - Run tests or linters to verify
   - Any other maintenance commands
$EXPLORATION_INSTRUCTION$AGENT_INSTRUCTION

${IMAGE_SECTION}${FEEDBACK_SECTION}$(if [[ -n "$EVAL_TAIL" ]]; then echo "### Signals from evaluators"; echo '```'; echo "$EVAL_TAIL"; echo '```'; echo ""; fi)

$(if [[ -n "$CHANGED_FILES_PREVIEW" ]]; then echo "### Recent changes"; echo '```'; echo "$CHANGED_FILES_PREVIEW"; echo '```'; fi)

---

**Make ONE improvement toward the goal, then reply with a brief summary.**"
fi

# Debug: Write full prompt to log file
DEBUG_PROMPT_FILE="$LOOP_DIR/debug-prompt.txt"
{
  echo "============================================================"
  echo "DEBUG: Full prompt sent to Claude Code"
  echo "UTC: $(utc_now)"
  echo "Iteration: $ITERATION"
  echo "============================================================"
  echo ""
  echo "=== SYSTEM MESSAGE ==="
  echo "$SYSTEM_MSG"
  echo ""
  echo "=== REASON PROMPT ==="
  echo "$REASON_PROMPT"
  echo ""
  echo "=== AGENT INSTRUCTION (if any) ==="
  echo "$AGENT_INSTRUCTION"
  echo ""
  echo "=== AGENTS CATALOG (if discovered) ==="
  echo "${AGENTS_CATALOG:-<none>}"
  echo ""
} > "$DEBUG_PROMPT_FILE"
echo "📝 Debug prompt written to: $DEBUG_PROMPT_FILE" >&2

# Block stop and feed prompt back
jq -n \
  --arg prompt "$REASON_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'
