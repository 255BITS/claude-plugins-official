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

1. **Discover the project** - Run these commands to understand the codebase:
   ```bash
   # List top-level directories (potential --dir targets)
   ls -d */ 2>/dev/null | head -20

   # Detect project type
   ls package.json pyproject.toml Makefile Cargo.toml go.mod setup.py requirements.txt 2>/dev/null || echo "No standard project files found"
   ```

2. **Ask the user** using AskUserQuestion with smart suggestions based on what you found:
   - **Target directory**: Suggest directories that look like good candidates (src/, lib/, app/, components/, etc.)
   - **Goal**: Ask what they want to improve (code quality, add features, fix bugs, etc.)
   - **Iterations**: How many iterations? Default is 3. Options: 3 (quick), 5 (medium), 10 (thorough)
   - **Command** (optional): Suggest based on project type:
     - package.json → `npm test` or `npm run build`
     - pyproject.toml/setup.py → `pytest` or `python -m pytest`
     - Makefile → `make test` or `make`
     - Cargo.toml → `cargo test`
     - go.mod → `go test ./...`
     - Or "None" if no verification needed

3. **Run the setup** with the gathered parameters:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-loop.sh --dir DIR --goal "GOAL" --max-iterations N [--cmd "CMD"]
   ```

---

The loop runs via a **Stop hook**:
- Makes improvements via **Claude Code** (default) or **external LLM** (if `GPTDIFF_LLM_API_KEY` is set)
- Iterates until `--max-iterations` is reached

Cancel anytime with: `/cancel-gptdiff-loop`

After setup, respond with a short progress note (or just `ok`). The loop will take over from here.
