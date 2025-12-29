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

4. **Ask about goal with SPECIFIC suggestions** based on what you found:
   - If it's UI code: "Improve UI responsiveness", "Add animations", "Improve accessibility"
   - If it's game content: "Add more variety", "Balance values", "Make it more fun"
   - If it's API/backend: "Add error handling", "Improve validation", "Add logging"
   - If it's data/models: "Add new fields", "Improve schema", "Add validation"
   - Make suggestions specific to the actual file contents you read!

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
