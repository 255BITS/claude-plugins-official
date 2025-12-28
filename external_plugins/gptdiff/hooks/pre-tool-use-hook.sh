#!/bin/bash

# GPTDiff PreToolUse Hook
# Auto-approves bash commands that are part of this plugin's own scripts.
#
# This allows /gptdiff-loop and /gptdiff-scaffold commands to run without
# requiring manual permission approval from the user.

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT="$(cat)"

# Get the tool name
TOOL_NAME="$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty')"

# Only process Bash tool calls
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# Get the command being executed
COMMAND="$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty')"

# Get the plugin root directory (where this hook lives)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [[ -z "$PLUGIN_ROOT" ]]; then
  # Fallback: derive from this script's location
  PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Check if the command references our plugin scripts
# We match:
#   - Direct calls to our scripts (setup-gptdiff-loop.sh, scaffold-loop-dir.sh)
#   - Commands containing CLAUDE_PLUGIN_ROOT that point to our plugin
#
# Note: We use substring matching for safety - the command may have arguments

should_approve=false

# Pattern 1: Command starts with a quoted path to our scripts
if [[ "$COMMAND" == *"${PLUGIN_ROOT}/scripts/"* ]]; then
  should_approve=true
fi

# Pattern 2: Command contains CLAUDE_PLUGIN_ROOT variable reference to our scripts
if [[ "$COMMAND" == *'${CLAUDE_PLUGIN_ROOT}/scripts/'* ]]; then
  should_approve=true
fi
if [[ "$COMMAND" == *'"${CLAUDE_PLUGIN_ROOT}/scripts/'* ]]; then
  should_approve=true
fi

# Pattern 3: Inline bash for cancel-gptdiff-loop (check state file operations)
# This matches the inline script in cancel-gptdiff-loop.md
if [[ "$COMMAND" == *'STATE_FILE=".claude/gptdiff-loop.local.md"'* ]]; then
  should_approve=true
fi

# Pattern 4: Simple rm of the state file (from cancel command's second step)
if [[ "$COMMAND" == "rm .claude/gptdiff-loop.local.md" ]] || \
   [[ "$COMMAND" == "rm -f .claude/gptdiff-loop.local.md" ]]; then
  should_approve=true
fi

if [[ "$should_approve" == "true" ]]; then
  # Auto-approve this command
  echo '{"permissionDecision": "allow"}'
else
  # Let normal permission flow handle it
  exit 0
fi
