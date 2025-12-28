#!/bin/bash

# GPTDiff Stop Hook
#
# Implements an in-session agent loop that repeatedly runs:
#   - optional eval command (signals/metrics)
#   - optional hard-gate command (stop when it passes)
#   - gptdiff --apply (iterative improvement)
#
# The loop is activated by /gptdiff-loop which creates:
#   .claude/gptdiff-loop.local.md
#
# This hook is intentionally "Ralph-adjacent": it blocks Stop and feeds a short
# prompt back each iteration so the user can watch progress.

set -euo pipefail

# Consume hook input (Stop hook API provides JSON on stdin)
_HOOK_INPUT="$(cat || true)"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_FILE="$ROOT_DIR/.claude/gptdiff-loop.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  # No active loop - allow normal stop
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  GPTDiff loop: 'jq' is required for stop hook JSON responses. Stopping loop." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

if ! command -v gptdiff >/dev/null 2>&1; then
  echo "⚠️  GPTDiff loop: 'gptdiff' not found on PATH. Install with: pip install gptdiff" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

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

ITERATION="$(strip_yaml_quotes "$(yaml_get_raw iteration)")"
MAX_ITERATIONS="$(strip_yaml_quotes "$(yaml_get_raw max_iterations)")"
TARGET_DIR="$(yaml_unescape "$(strip_yaml_quotes "$(yaml_get_raw target_dir)")")"
GOAL="$(yaml_unescape "$(strip_yaml_quotes "$(yaml_get_raw goal)")")"
TEMPLATE="$(yaml_unescape "$(strip_yaml_quotes "$(yaml_get_raw template)")")"
CMD_RAW="$(yaml_get_raw cmd)"
EVAL_CMD_RAW="$(yaml_get_raw eval_cmd)"
MODEL_RAW="$(yaml_get_raw model)"

CMD="$(yaml_unescape "$(strip_yaml_quotes "$CMD_RAW")")"
EVAL_CMD="$(yaml_unescape "$(strip_yaml_quotes "$EVAL_CMD_RAW")")"
MODEL="$(yaml_unescape "$(strip_yaml_quotes "$MODEL_RAW")")"

# Normalize null-like values
if [[ "${CMD_RAW:-}" == "null" ]] || [[ -z "${CMD:-}" ]]; then CMD=""; fi
if [[ "${EVAL_CMD_RAW:-}" == "null" ]] || [[ -z "${EVAL_CMD:-}" ]]; then EVAL_CMD=""; fi
if [[ "${MODEL_RAW:-}" == "null" ]] || [[ -z "${MODEL:-}" ]]; then MODEL=""; fi
if [[ -z "${TEMPLATE:-}" ]] || [[ "${TEMPLATE:-}" == "null" ]]; then TEMPLATE="generic"; fi

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

if [[ -z "${TARGET_DIR:-}" ]]; then
  echo "⚠️  GPTDiff loop: State file corrupted (target_dir missing)." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

TARGET_ABS="$ROOT_DIR/$TARGET_DIR"
if [[ ! -d "$TARGET_ABS" ]]; then
  echo "⚠️  GPTDiff loop: target_dir does not exist: $TARGET_ABS" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

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

# Logs are kept per target directory
TARGET_SLUG="$(echo "$TARGET_DIR" | sed 's#[^A-Za-z0-9._-]#_#g')"
LOOP_DIR="$ROOT_DIR/.claude/gptdiff-loop/$TARGET_SLUG"
mkdir -p "$LOOP_DIR"

EVAL_LOG="$LOOP_DIR/eval.log"
CMD_LOG="$LOOP_DIR/cmd.log"
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
    echo "Target: $TARGET_DIR"
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
    GPTDIFF_LOOP_TARGET_DIR="$TARGET_DIR" bash -lc "$EVAL_CMD"
  ) >> "$EVAL_LOG" 2>&1
  EVAL_EXIT=$?
  set -e
  echo "" >> "$EVAL_LOG"
fi

# Optional hard gate command (stop when it passes)
CMD_EXIT=0
if [[ -n "$CMD" ]]; then
  append_header "$CMD_LOG" "CMD"
  set +e
  (
    cd "$ROOT_DIR" || exit 127
    GPTDIFF_LOOP_TARGET_DIR="$TARGET_DIR" bash -lc "$CMD"
  ) >> "$CMD_LOG" 2>&1
  CMD_EXIT=$?
  set -e
  echo "" >> "$CMD_LOG"

  if [[ $CMD_EXIT -eq 0 ]]; then
    echo "✅ GPTDiff loop: Hard gate command succeeded. Stopping loop." >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
fi

# Build the GPTDiff goal prompt.
# The interface files live inside the target directory (scaffolded), so GPTDiff sees them.
EVAL_TAIL=""
if [[ -f "$EVAL_LOG" ]]; then
  EVAL_TAIL="$(tail -n 80 "$EVAL_LOG" | sed 's/\r$//')"
fi

CMD_TAIL=""
if [[ -f "$CMD_LOG" ]]; then
  CMD_TAIL="$(tail -n 80 "$CMD_LOG" | sed 's/\r$//')"
fi

GPTDIFF_PROMPT="You are running an iterative GPTDiff agent loop.

Iteration: $ITERATION / $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
Target directory: $TARGET_DIR
Template: $TEMPLATE

GOAL:
$GOAL

CONSTRAINTS:
- Follow INTERFACE.md in this directory as the contract.
- If RUBRIC.md exists, use it to guide improvements.
- Make one coherent, meaningful improvement per iteration (small, reviewable diffs).
- Preserve existing intent and structure; avoid unnecessary rewrites.
- Do not add broken JSON/YAML/Markdown; keep ids stable and avoid duplicates.

SIGNALS (optional):
--- eval (tail) ---
$EVAL_TAIL

--- cmd (tail) ---
$CMD_TAIL
"

append_header "$GPTDIFF_LOG" "GPTDIFF"
{
  echo "Goal prompt:"
  echo "$GPTDIFF_PROMPT"
  echo ""
  echo "----- gptdiff output -----"
} >> "$GPTDIFF_LOG"

# Run gptdiff within the target directory (keeps diffs scoped; uses that dir's .gptignore)
GPTDIFF_EXIT=0
set +e
(
  cd "$TARGET_ABS" || exit 127
  if [[ -n "$MODEL" ]]; then
    gptdiff "$GPTDIFF_PROMPT" --model "$MODEL" --apply --nobeep
  else
    gptdiff "$GPTDIFF_PROMPT" --apply --nobeep
  fi
) >> "$GPTDIFF_LOG" 2>&1
GPTDIFF_EXIT=$?
set -e
echo "" >> "$GPTDIFF_LOG"
echo "gptdiff exit: $GPTDIFF_EXIT" >> "$GPTDIFF_LOG"
echo "" >> "$GPTDIFF_LOG"

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

# If next iteration would exceed max, stop on next stop attempt
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $NEXT_ITERATION -gt $MAX_ITERATIONS ]]; then
  SYSTEM_MSG="🛑 GPTDiff loop will stop next cycle (max iterations reached). Review git diff."
else
  SYSTEM_MSG="🔁 GPTDiff loop active | next iter: $NEXT_ITERATION | target: $TARGET_DIR | logs: .claude/gptdiff-loop/$TARGET_SLUG/ | cancel: /cancel-gptdiff-loop"
fi

CHANGED_FILES_PREVIEW="$(tail -n 40 "$CHANGED_FILES_FILE" 2>/dev/null || true)"
DIFFSTAT_PREVIEW="$(tail -n 80 "$DIFFSTAT_FILE" 2>/dev/null || true)"

REASON_PROMPT="$BASE_PROMPT

Loop status:
+- Target: $TARGET_DIR
+- Iteration just ran: $ITERATION
+- Next iteration: $NEXT_ITERATION
+- gptdiff exit: $GPTDIFF_EXIT
+- eval exit: $EVAL_EXIT
+- cmd exit: $CMD_EXIT

Changed files (preview):
+$CHANGED_FILES_PREVIEW

Diffstat (preview):
+$DIFFSTAT_PREVIEW

Please reply with 1–5 bullets: what changed + what to improve next, then stop."

# Block stop and feed prompt back
jq -n \
  --arg prompt "$REASON_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'
