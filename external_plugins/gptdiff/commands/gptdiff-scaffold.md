---
description: "Scaffold a subdirectory for GPTDiff loops (.gptignore + interface files)"
argument-hint: "--dir PATH [--template generic|game-world] [--overwrite]"
allowed-tools: ["Bash"]
---

# GPTDiff Scaffold

This creates a focused “domain workspace” directory with:
- `.gptignore` (avoid slurping assets/build outputs)
- `INTERFACE.md` (explicit contract)
- optionally `RUBRIC.md` (for creative domains)

Run this script using the Bash tool (replace $ARGUMENTS with the user's arguments):
```
/home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/scaffold-loop-dir.sh $ARGUMENTS
```
