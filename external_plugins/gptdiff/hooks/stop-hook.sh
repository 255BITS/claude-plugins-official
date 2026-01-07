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

# Parse session_id from hook input - this is the authoritative session identifier
HOOK_SESSION_ID=""
if command -v jq >/dev/null 2>&1 && [[ -n "$_HOOK_INPUT" ]]; then
  HOOK_SESSION_ID="$(echo "$_HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

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

# Multi-instance safety: Find a loop we can claim
# Each loop has a .lock-owner file with the session ID that owns it
# We also track .last-activity to detect stale locks

# Use session_id from hook input - this is the authoritative session identifier
# Debug logging
DEBUG_LOG="$ROOT_DIR/.claude/gptdiff-debug.log"
mkdir -p "$(dirname "$DEBUG_LOG")"
{
  echo "=== Stop hook invoked: $(date) ==="
  echo "ROOT_DIR: $ROOT_DIR"
  echo "HOOK_SESSION_ID: $HOOK_SESSION_ID"
  echo "STATE_FILES found: ${#STATE_FILES[@]}"
  for sf in "${STATE_FILES[@]}"; do
    echo "  - $sf"
    echo "    .lock-owner: $(cat "$(dirname "$sf")/.lock-owner" 2>/dev/null || echo 'NONE')"
  done
} >> "$DEBUG_LOG"

# Use hook-provided session_id (always available in Claude Code hooks)
if [[ -n "$HOOK_SESSION_ID" ]]; then
  OUR_SESSION_ID="$HOOK_SESSION_ID"
else
  # Fallback for edge cases (shouldn't happen in normal operation)
  OUR_SESSION_ID="unknown-session-$(date +%s)-$$"
fi

echo "OUR_SESSION_ID: $OUR_SESSION_ID" >> "$DEBUG_LOG"

# Stale lock timeout: 10 minutes (600 seconds)
# If a lock hasn't been updated in this time, consider it abandoned
STALE_LOCK_TIMEOUT=600

find_claimable_loop() {
  local now
  now=$(date +%s)

  echo "=== find_claimable_loop called ===" >> "$DEBUG_LOG"

  for state_file in "${STATE_FILES[@]}"; do
    local loop_dir
    loop_dir="$(dirname "$state_file")"
    local lock_owner_file="$loop_dir/.lock-owner"
    local last_activity_file="$loop_dir/.last-activity"

    echo "Checking loop: $loop_dir" >> "$DEBUG_LOG"
    echo "  lock_owner_file exists: $(test -f "$lock_owner_file" && echo yes || echo no)" >> "$DEBUG_LOG"

    # Check if there's an existing lock owner
    if [[ -f "$lock_owner_file" ]]; then
      local lock_owner
      lock_owner="$(cat "$lock_owner_file" 2>/dev/null || echo "")"

      echo "  lock_owner content: '$lock_owner'" >> "$DEBUG_LOG"
      echo "  OUR_SESSION_ID: '$OUR_SESSION_ID'" >> "$DEBUG_LOG"
      echo "  match: $(test "$lock_owner" == "$OUR_SESSION_ID" && echo yes || echo no)" >> "$DEBUG_LOG"

      # Check for pending claim token (newly started loop, not yet claimed by stop hook)
      # Pending tokens look like: pending-1234567890-abc123
      # Only claim if very recent (< 30 seconds) to avoid cross-session races
      if [[ "$lock_owner" == pending-* ]]; then
        if [[ -f "$last_activity_file" ]]; then
          local pending_age=$((now - $(cat "$last_activity_file" 2>/dev/null || echo 0)))
          if [[ $pending_age -lt 30 ]]; then
            # This is a freshly started loop - claim it with our real session_id
            echo "  -> CLAIMING (pending claim token ${pending_age}s old, upgrading to session_id)" >> "$DEBUG_LOG"
            echo "$OUR_SESSION_ID" > "$lock_owner_file"
            echo "$now" > "$last_activity_file"
            echo "$state_file"
            return 0
          else
            echo "  -> SKIP (pending token too old: ${pending_age}s, may belong to another session)" >> "$DEBUG_LOG"
            continue
          fi
        else
          # No activity file - claim it
          echo "  -> CLAIMING (pending claim token, no activity file)" >> "$DEBUG_LOG"
          echo "$OUR_SESSION_ID" > "$lock_owner_file"
          echo "$now" > "$last_activity_file"
          echo "$state_file"
          return 0
        fi
      fi

      # If we own this lock, verify the loop is actually active
      # (last-activity must be recent - this prevents stale session files from matching)
      if [[ "$lock_owner" == "$OUR_SESSION_ID" ]]; then
        if [[ -f "$last_activity_file" ]]; then
          local last_activity
          last_activity="$(cat "$last_activity_file" 2>/dev/null || echo 0)"
          local activity_age=$((now - last_activity))
          echo "  last_activity age: ${activity_age}s" >> "$DEBUG_LOG"

          # If last activity was more than 15 minutes ago, this might be a stale session file
          # matching an old loop. Require the user to explicitly restart.
          if [[ $activity_age -gt 900 ]]; then
            echo "  -> SKIP (session ID matches but loop inactive for ${activity_age}s)" >> "$DEBUG_LOG"
            echo "⚠️  Loop $(basename "$loop_dir") has matching session but was inactive for ${activity_age}s" >&2
            echo "   The previous Claude session may have ended. Use /gptdiff:start to restart." >&2
            continue
          fi
        fi
        echo "  -> CLAIMING (owner match, loop active)" >> "$DEBUG_LOG"
        echo "$state_file"
        return 0
      fi

      # Check if the lock is stale
      if [[ -f "$last_activity_file" ]]; then
        local last_activity
        last_activity="$(cat "$last_activity_file" 2>/dev/null || echo 0)"
        local age=$((now - last_activity))

        if [[ $age -gt $STALE_LOCK_TIMEOUT ]]; then
          # Stale lock - break it and claim this loop
          echo "⚠️  Breaking stale lock on loop $(basename "$loop_dir") (inactive for ${age}s)" >&2
          echo "$OUR_SESSION_ID" > "$lock_owner_file"
          echo "$now" > "$last_activity_file"
          echo "$state_file"
          return 0
        else
          # Lock is held by another active instance - skip this loop
          echo "ℹ️  Loop $(basename "$loop_dir") is owned by another instance (last active ${age}s ago)" >&2
          continue
        fi
      else
        # No activity file but lock exists - treat as new, claim it
        echo "$OUR_SESSION_ID" > "$lock_owner_file"
        echo "$now" > "$last_activity_file"
        echo "$state_file"
        return 0
      fi
    else
      # No lock owner file - orphan loop, claim it
      echo "  -> CLAIMING (no lock file, orphan loop)" >> "$DEBUG_LOG"
      echo "$OUR_SESSION_ID" > "$lock_owner_file"
      echo "$now" > "$last_activity_file"
      echo "$state_file"
      return 0
    fi
  done

  # No claimable loops found
  echo "=== No claimable loops found ===" >> "$DEBUG_LOG"
  return 1
}

# Find a loop we can claim
STATE_FILE=""
if ! STATE_FILE="$(find_claimable_loop)"; then
  # All loops are owned by other instances
  if [[ ${#STATE_FILES[@]} -gt 0 ]]; then
    echo "ℹ️  All ${#STATE_FILES[@]} loop(s) are owned by other Claude instances." >&2
    echo "   Use /gptdiff:stop to force-cancel all loops, or wait for them to complete." >&2
  fi
  exit 0
fi

if [[ -z "$STATE_FILE" ]]; then
  # No state file found (shouldn't happen, but be safe)
  exit 0
fi

# Get the loop directory for this state file
LOOP_DIR_FOR_LOCK="$(dirname "$STATE_FILE")"

# Update last activity timestamp to keep our lock fresh
echo "$(date +%s)" > "$LOOP_DIR_FOR_LOCK/.last-activity"

# If multiple loops are active, warn the user
if [[ ${#STATE_FILES[@]} -gt 1 ]]; then
  echo "⚠️  Multiple loops active (${#STATE_FILES[@]} loops). Processing owned loop: $(basename "$LOOP_DIR_FOR_LOCK")" >&2
  echo "   All active loops:" >&2
  for sf in "${STATE_FILES[@]}"; do
    local_loop_dir="$(dirname "$sf")"
    local_owner="$(cat "$local_loop_dir/.lock-owner" 2>/dev/null || echo "unknown")"
    if [[ "$local_owner" == "$OUR_SESSION_ID" ]]; then
      echo "   - $(basename "$local_loop_dir") (owned by this instance)" >&2
    else
      echo "   - $(basename "$local_loop_dir") (owned by: ${local_owner:0:20}...)" >&2
    fi
  done
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  Loop error: 'jq' is required for stop hook JSON responses. Stopping loop." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Check that Python and gptdiff package are available (for file loading utilities)
if ! python3 -c "import gptdiff" 2>/dev/null; then
  echo "⚠️  Loop error: 'gptdiff' Python package not found. Install with: pip install gptdiff" >&2
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
  echo "⚠️  Loop error: State file corrupted (iteration is not a number)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Loop error: State file corrupted (max_iterations is not a number)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

if [[ -z "${TARGET_DIRS_STR:-}" ]] && [[ -z "${TARGET_FILES_STR:-}" ]]; then
  echo "⚠️  Loop error: State file corrupted (no target_dirs or target_files)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Validate all target directories exist
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  TARGET_ABS="$ROOT_DIR/$dir"
  if [[ ! -d "$TARGET_ABS" ]]; then
    echo "⚠️  Loop error: target directory does not exist: $TARGET_ABS" >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
done <<< "$TARGET_DIRS_STR"

# Validate all target files exist
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  TARGET_ABS="$ROOT_DIR/$file"
  if [[ ! -f "$TARGET_ABS" ]]; then
    echo "⚠️  Loop error: target file does not exist: $TARGET_ABS" >&2
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

# If max iterations exceeded, show summary and clean up
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -gt $MAX_ITERATIONS ]]; then
  echo "🛑 Loop complete: $MAX_ITERATIONS iterations finished." >&2

  # Get git diff summary for the prompt
  FINAL_DIFFSTAT=""
  FINAL_LOG=""
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FINAL_DIFFSTAT="$(git -C "$ROOT_DIR" diff --stat 2>/dev/null | tail -20 || true)"
    FINAL_LOG="$(git -C "$ROOT_DIR" log --oneline -10 2>/dev/null || true)"
  fi

  # Clean up state file
  rm -f "$STATE_FILE"
  rm -f "$LOOP_DIR/.lock-owner"
  rm -f "$LOOP_DIR/.last-activity"

  # Return summary prompt
  SUMMARY_PROMPT="
╔══════════════════════════════════════════════════════════════════╗
║  ✅ LOOP COMPLETE - $MAX_ITERATIONS iterations                               ║
╚══════════════════════════════════════════════════════════════════╝

**Goal:** $GOAL
**Targets:** $TARGETS_DISPLAY

### Summary of changes
\`\`\`
$FINAL_DIFFSTAT
\`\`\`

### Recent commits
\`\`\`
$FINAL_LOG
\`\`\`

---

**Provide a brief summary of what was accomplished across all iterations.**
- What improved?
- What's the current state?
- Any suggested next steps?"

  jq -n \
    --arg prompt "$SUMMARY_PROMPT" \
    --arg msg "✅ Loop complete ($MAX_ITERATIONS iterations). Summarizing changes." \
    '{
      "decision": "block",
      "reason": $prompt,
      "systemMessage": $msg
    }'
  exit 0
fi

# Extract base prompt (everything after the closing ---)
BASE_PROMPT="$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")"
if [[ -z "$BASE_PROMPT" ]]; then
  BASE_PROMPT="Continue the loop. Reply with a short progress note, then stop."
fi

# LOOP_DIR was already set above from the state file's parent directory
mkdir -p "$LOOP_DIR"

# ============================================================
# AUTO-COMMIT: Commit changes from previous iteration (if any)
# ============================================================
# Only attempt commit on iteration 2+ (iteration 1 has no previous changes)
# Only commit if there are staged or unstaged changes in target dirs/files
if [[ $ITERATION -gt 1 ]] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Check if there are any changes (staged or unstaged)
  HAS_CHANGES="false"

  # Build list of targets for git add
  GIT_TARGETS=()
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    GIT_TARGETS+=("$ROOT_DIR/$dir")
  done <<< "$TARGET_DIRS_STR"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    GIT_TARGETS+=("$ROOT_DIR/$file")
  done <<< "$TARGET_FILES_STR"

  # Check for changes in target paths
  for target in "${GIT_TARGETS[@]}"; do
    if [[ -d "$target" ]] || [[ -f "$target" ]]; then
      # Check for unstaged changes
      if ! git -C "$ROOT_DIR" diff --quiet -- "$target" 2>/dev/null; then
        HAS_CHANGES="true"
        break
      fi
      # Check for staged changes
      if ! git -C "$ROOT_DIR" diff --cached --quiet -- "$target" 2>/dev/null; then
        HAS_CHANGES="true"
        break
      fi
      # Check for untracked files
      if [[ -d "$target" ]]; then
        UNTRACKED="$(git -C "$ROOT_DIR" ls-files --others --exclude-standard -- "$target" 2>/dev/null | head -1)"
        if [[ -n "$UNTRACKED" ]]; then
          HAS_CHANGES="true"
          break
        fi
      fi
    fi
  done

  if [[ "$HAS_CHANGES" == "true" ]]; then
    PREV_ITER=$((ITERATION - 1))

    # Stage changes in target directories/files
    for target in "${GIT_TARGETS[@]}"; do
      git -C "$ROOT_DIR" add "$target" 2>/dev/null || true
    done

    # Check if staging resulted in anything to commit (excludes whitespace-only changes)
    if ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
      # Get a brief summary of what changed
      CHANGED_COUNT="$(git -C "$ROOT_DIR" diff --cached --stat --stat-count=1 2>/dev/null | grep -oP '\d+ file' | grep -oP '\d+' || echo "?")"

      # Truncate goal for commit message (first 60 chars)
      GOAL_SHORT="${GOAL:0:60}"
      [[ ${#GOAL} -gt 60 ]] && GOAL_SHORT="${GOAL_SHORT}..."

      # Create commit
      COMMIT_MSG="[loop iter $PREV_ITER] $GOAL_SHORT

Automated commit from gptdiff loop iteration $PREV_ITER of $MAX_ITERATIONS.
Target: $TARGETS_DISPLAY

🤖 Generated with gptdiff loop"

      if git -C "$ROOT_DIR" commit -m "$COMMIT_MSG" >/dev/null 2>&1; then
        echo "✅ Committed iteration $PREV_ITER changes ($CHANGED_COUNT files)" >&2
      fi
    fi
  fi
fi

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
# NOTE: Only read on iteration 2+, since iteration 1 has no previous iteration
FEEDBACK_TAIL=""
if [[ $ITERATION -gt 1 ]] && [[ -f "$FEEDBACK_LOG" ]]; then
  FEEDBACK_TAIL="$(tail -n 100 "$FEEDBACK_LOG" | sed 's/\r$//')"
fi

# Get agent feedback from PREVIOUS iteration (if any)
# Include ALL agent feedback - it's valuable context even if long
# NOTE: Only read on iteration 2+, since iteration 1 has no previous iteration
# (avoids reading stale feedback from a previous loop with the same targets)
AGENT_FEEDBACK_FILE="$LOOP_DIR/agent-feedback.txt"
AGENT_FEEDBACK_CONTENT=""
if [[ $ITERATION -gt 1 ]] && [[ -f "$AGENT_FEEDBACK_FILE" ]]; then
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
    echo "⚠️  Loop: External LLM mode requested but GPTDIFF_LLM_API_KEY not set. Falling back to Claude Code." >&2
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
# Also refresh our lock activity timestamp to keep the lock alive
if [[ "${EXTERNAL_LLM_PENDING:-false}" != "true" ]]; then
  NEXT_ITERATION=$((ITERATION + 1))
  TEMP_FILE="${STATE_FILE}.tmp.$$"
  sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"

  # Refresh lock activity timestamp
  echo "$(date +%s)" > "$LOOP_DIR/.last-activity"
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
  SYSTEM_MSG="🛑 FINAL ITERATION $ITER_INFO - Loop complete after this. Review: git diff"
else
  if [[ "$USE_EXTERNAL_LLM" == "true" ]]; then
    SYSTEM_MSG="🔁 $ITER_INFO | $TARGETS_DISPLAY | External LLM | /stop to stop"
  else
    SYSTEM_MSG="🔁 $ITER_INFO | $TARGETS_DISPLAY | /stop to stop"
  fi
fi

CHANGED_FILES_PREVIEW="$(tail -n 40 "$CHANGED_FILES_FILE" 2>/dev/null || true)"
DIFFSTAT_PREVIEW="$(tail -n 80 "$DIFFSTAT_FILE" 2>/dev/null || true)"

# Build the prompt based on inference mode
if [[ "$USE_EXTERNAL_LLM" == "true" ]] && [[ "${EXTERNAL_LLM_PENDING:-false}" == "true" ]]; then
  # External LLM is still processing - ask Claude to wait
  REASON_PROMPT="
╔══════════════════════════════════════════════════════════════════╗
║  ⏳ LOOP - WAITING FOR EXTERNAL LLM                              ║
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
║  🔁 LOOP - ITERATION $ITERATION of $(printf "%-3s" "$(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "∞"; fi)")                                  ║
╚══════════════════════════════════════════════════════════════════╝

**Mode:** External LLM
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
  # Display as markdown (not code block) so the agent's voice comes through naturally
  if [[ -n "$AGENT_FEEDBACK_CONTENT" ]]; then
    FEEDBACK_SECTION+="### 🧑‍💼 Feedback Agent Says:

$AGENT_FEEDBACK_CONTENT

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

  # Build agent feedback instruction if feedback_agent is set
  AGENT_INSTRUCTION=""

  # If feedback_agent is enabled, require spawning a subagent for feedback
  if [[ -n "$FEEDBACK_AGENT" ]]; then
    AGENT_INSTRUCTION="### ⚠️ MANDATORY: Spawn a subagent for feedback

**YOU MUST USE THE TASK TOOL TO SPAWN A SUBAGENT BEFORE MAKING ANY CHANGES.**

**AGENT SELECTION - Favor specific agents over generic ones:**
- Review your Task tool's \"Available agent types\" list
- **PREFER domain-specific agents** that match the goal (e.g., writer, editor, designer, strategist, product manager)
- **AVOID generic agents** like \"general-purpose\" or \"Explore\" unless no specific agent fits
- Match the goal keywords to agent specialties (e.g., \"docs\" → writer/editor, \"UI\" → designer, \"strategy\" → strategist)

**REQUIRED STEPS (in order):**

1. **Use the Task tool NOW** with the most relevant specialized subagent_type:
   - Prompt: \"Review this for: $GOAL. Find ONE specific improvement and explain why it matters.\"

2. **Save feedback** to \`$AGENT_FEEDBACK_FILE\`

3. **Make ONE change** based on agent's recommendation

4. **Respond 'ok'**

**DO NOT skip the subagent. DO NOT invent agent types.**"
  else
    AGENT_INSTRUCTION="### This iteration
1. **Pick ONE improvement** toward the goal
2. **Make the change**
3. **Respond 'ok'** to end turn"
  fi

  REASON_PROMPT="
╔══════════════════════════════════════════════════════════════════╗
║  🔁 LOOP - ITERATION $ITERATION of $(printf "%-3s" "$(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "∞"; fi)")                                  ║
╚══════════════════════════════════════════════════════════════════╝

**⚠️ CRITICAL: You MUST complete this iteration. Do NOT stop the loop early.**

### Goal (directional - make progress, don't try to finish)
$GOAL

### Progress
$ITER_INFO

$AGENT_INSTRUCTION

### Rules
- **DO NOT** stop the loop early, announce \"done\", or ask to continue
- **DO** make one small change per iteration
- The loop ends when max iterations reached

${IMAGE_SECTION}${FEEDBACK_SECTION}$(if [[ -n "$EVAL_TAIL" ]]; then echo "### Signals"; echo '```'; echo "$EVAL_TAIL"; echo '```'; echo ""; fi)

$(if [[ -n "$CHANGED_FILES_PREVIEW" ]]; then echo "### Recent changes"; echo '```'; echo "$CHANGED_FILES_PREVIEW"; echo '```'; fi)

---

**Make ONE change, then respond \"ok\" to end your turn. Next iteration starts automatically.**"
fi

# Debug: Write full prompt to log file
DEBUG_PROMPT_FILE="$LOOP_DIR/debug-prompt.txt"
{
  echo "============================================================"
  echo "DEBUG: Full prompt sent to Claude"
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
