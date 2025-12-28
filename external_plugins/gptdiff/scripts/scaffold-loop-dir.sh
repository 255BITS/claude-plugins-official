#!/bin/bash

# Scaffold a target subdirectory for GPTDiff loops:
# - adds .gptignore
# - adds INTERFACE.md
# - optionally adds RUBRIC.md (game-world template)

set -euo pipefail

show_help() {
  cat << 'HELP_EOF'
GPTDiff Scaffold

USAGE:
  /gptdiff-scaffold --dir PATH [--template generic|game-world] [--overwrite]

OPTIONS:
  --dir PATH                  Target directory to scaffold (required)
  --template NAME             Template: generic | game-world (default: generic)
  --overwrite                 Overwrite existing .gptignore / INTERFACE.md / RUBRIC.md
  -h, --help                  Show this help

EXAMPLES:
  /gptdiff-scaffold --dir items --template game-world
  /gptdiff-scaffold --dir interactions --template generic --overwrite
HELP_EOF
}

TARGET_DIR=""
TEMPLATE="generic"
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
    --template)
      TEMPLATE="${2:-}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE="true"
      shift
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "   Try: /gptdiff-scaffold --help" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  echo "❌ Error: --dir PATH is required" >&2
  exit 1
fi

case "$TEMPLATE" in
  generic|game-world) ;;
  *)
    echo "❌ Error: --template must be 'generic' or 'game-world' (got: $TEMPLATE)" >&2
    exit 1
    ;;
esac

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMMON_GPTIGNORE="$PLUGIN_ROOT/templates/common/.gptignore"
GENERIC_INTERFACE="$PLUGIN_ROOT/templates/generic/INTERFACE.md"
GAME_INTERFACE="$PLUGIN_ROOT/templates/game-world/INTERFACE.md"
GAME_RUBRIC="$PLUGIN_ROOT/templates/game-world/RUBRIC.md"

mkdir -p "$TARGET_DIR"

copy_if_needed() {
  local src="$1"
  local dst="$2"
  local label="$3"
  if [[ ! -f "$dst" ]] || [[ "$OVERWRITE" == "true" ]]; then
    cp "$src" "$dst"
    echo "✅ Wrote $label: $dst"
  else
    echo "↪︎ Kept existing $label: $dst"
  fi
}

copy_if_needed "$COMMON_GPTIGNORE" "$TARGET_DIR/.gptignore" ".gptignore"

if [[ "$TEMPLATE" == "generic" ]]; then
  copy_if_needed "$GENERIC_INTERFACE" "$TARGET_DIR/INTERFACE.md" "INTERFACE.md"
else
  copy_if_needed "$GAME_INTERFACE" "$TARGET_DIR/INTERFACE.md" "INTERFACE.md"
  copy_if_needed "$GAME_RUBRIC" "$TARGET_DIR/RUBRIC.md" "RUBRIC.md"
fi

cat <<EOF

Scaffold complete.

Target: $TARGET_DIR
Template: $TEMPLATE

Next:
  /gptdiff-loop --dir "$TARGET_DIR" --template "$TEMPLATE" --goal "..." --max-iterations 10
EOF
