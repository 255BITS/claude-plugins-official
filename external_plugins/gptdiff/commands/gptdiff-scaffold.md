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

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/scaffold-loop-dir.sh" $ARGUMENTS
```
