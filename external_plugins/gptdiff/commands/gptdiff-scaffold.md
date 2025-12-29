---
description: "Scaffold a subdirectory for GPTDiff loops (.gptignore + interface files)"
argument-hint: "--dir PATH [--template generic|game-world] [--overwrite]"
allowed-tools: ["Bash", "Glob", "AskUserQuestion"]
---

# GPTDiff Scaffold

This creates a focused "domain workspace" directory with:
- `.gptignore` (avoid slurping assets/build outputs)
- `INTERFACE.md` (explicit contract)
- optionally `RUBRIC.md` (for creative domains)

## If arguments are provided ($ARGUMENTS is not empty):

Run the scaffold script directly:
```
/home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/scaffold-loop-dir.sh $ARGUMENTS
```

## If NO arguments provided (empty $ARGUMENTS):

Help the user choose interactively:

1. **List available directories**:
   ```bash
   ls -d */ 2>/dev/null | head -20
   ```

2. **Ask the user** using AskUserQuestion:
   - **Target directory**: Which directory to scaffold (suggest src/, lib/, app/, etc.)
   - **Template**: "generic" (default) or "game-world" (adds RUBRIC.md for creative evaluation)

3. **Run the scaffold** with gathered parameters:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/scaffold-loop-dir.sh --dir DIR --template TEMPLATE
   ```
