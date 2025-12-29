---
description: "Start a GPTDiff-powered agent loop on a subdirectory"
argument-hint: "--dir PATH --goal '...' [--max-iterations N] [--cmd '...'] [--eval-cmd '...'] [--model MODEL]"
allowed-tools: ["Bash", "Glob", "Read", "AskUserQuestion"]
---

# GPTDiff Loop

## If arguments are provided ($ARGUMENTS is not empty):

Run the setup script directly:
```
/home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-loop.sh $ARGUMENTS
```

## If NO arguments provided (empty $ARGUMENTS):

Help the user configure the loop interactively:

1. **Discover the project structure**:
   ```bash
   ls -d */ 2>/dev/null | head -20
   ls package.json pyproject.toml Makefile Cargo.toml go.mod 2>/dev/null || true
   ```

2. **Ask about target directory first** using AskUserQuestion:
   - Suggest directories that look like good candidates (src/, lib/, app/, components/, etc.)

3. **After user picks a directory, analyze its contents**:
   - List files in the chosen directory: `ls -la <dir>/`
   - Read 2-3 key files to understand what the code does
   - Identify the domain: UI components? API endpoints? Game content? Data models? Utils?

4. **Ask about goal with SPECIFIC, DIRECTIONAL suggestions** based on what you read:
   - Be specific to the actual content: if you see enemies.ts with 3 enemies, suggest "Add 2-3 new enemy types with unique abilities"
   - Be directional (add/improve/expand/polish/fix): "Add more upgrade options", "Improve damage scaling", "Expand the skill tree"
   - Reference actual things in the code: "Add more items like {example from file}", "Balance the {thing you saw}"
   - Examples of good directional goals:
     - "Add 3-4 new passive abilities that synergize with existing ones"
     - "Improve the shop UI with better item previews and sorting"
     - "Expand enemy variety - add ranged and boss variants"
     - "Polish the combat feel - add screen shake, hit feedback"
   - DON'T be generic like "improve code quality" - be specific to what's actually there!

5. **Ask about iterations and command**:
   - Iterations: 3 (quick), 5 (medium), 10 (thorough)
   - Command: Based on project type, or "None"

6. **Run the setup** with the gathered parameters:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-loop.sh --dir DIR --goal "GOAL" --max-iterations N [--cmd "CMD"]
   ```

---

The loop runs via a **Stop hook** and iterates until `--max-iterations` is reached.

Cancel anytime with: `/cancel-gptdiff-loop`

After setup, respond with a short progress note (or just `ok`). The loop will take over from here.
