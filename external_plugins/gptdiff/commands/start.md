---
description: "Start a GPTDiff-powered agent loop on directories or files"
argument-hint: "<goal> | --dir PATH --goal '...' [--feedback-cmd CMD] [--max-iterations N]"
allowed-tools: ["Bash", "Glob", "Read", "AskUserQuestion"]
---

# GPTDiff Loop

## If $ARGUMENTS contains `--dir` or `--file` flags:

Run the setup script directly:
```
/home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-start.sh $ARGUMENTS
```

## If $ARGUMENTS is a plain goal (no flags) like "make the game better":

The user provided a goal directly. Auto-discover the right files:

1. **Discover the project structure**:
   ```bash
   ls -d */ 2>/dev/null | head -20
   ls *.ts *.js *.py *.tsx *.jsx 2>/dev/null | head -10 || true
   ls package.json pyproject.toml Makefile Cargo.toml go.mod 2>/dev/null || true
   ```

2. **Analyze which directories/files are relevant to the goal**:
   - Look at the goal text and find directories that match
   - For "game" goals: look for src/, game/, content/, data/, etc.
   - For "UI" goals: look for components/, ui/, views/, etc.
   - Read a few key files to confirm they're relevant
   - Pick 1-3 most relevant directories or files

3. **Ask about configuration** using AskUserQuestion with MULTIPLE questions:

   Ask these in a SINGLE AskUserQuestion call with multiple questions:

   **Question 1: Iterations**
   - Show what directories/files you found
   - Options: 3 (quick), 5 (medium), 10 (thorough)

   **Question 2: Agent Feedback**
   - **Auto (Recommended)**: Spawn agents to review changes each iteration (Claude decides what kind based on goal)
   - **None**: No agent feedback between iterations

   Note: User can also type a custom agent description like "security expert" or "game designer"

4. **Run the setup**:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-start.sh --dir DIR [--dir DIR2] --goal "THE_GOAL_FROM_ARGUMENTS" --max-iterations N --feedback-agent AGENT
   ```
   Where AGENT is "auto", a custom description, or omitted for none.

## If NO arguments provided (empty $ARGUMENTS):

Full interactive mode:

1. **Discover the project structure**:
   ```bash
   ls -d */ 2>/dev/null | head -20
   ls package.json pyproject.toml Makefile Cargo.toml go.mod 2>/dev/null || true
   ```

2. **Ask about target directories/files** using AskUserQuestion:
   - Suggest directories that look like good candidates (src/, lib/, app/, components/, etc.)

3. **After user picks targets, analyze their contents**:
   - List files: `ls -la <dir>/`
   - Read 2-3 key files to understand the code
   - Identify the domain: UI? API? Game content? Data models?

4. **Ask about configuration** using AskUserQuestion with MULTIPLE questions:

   Ask these in a SINGLE AskUserQuestion call with multiple questions:

   **Question 1: Goal**
   - Be specific: if you see enemies.ts with 3 enemies, suggest "Add 2-3 new enemy types"
   - Be directional: "Add more X", "Improve Y", "Expand Z", "Polish W"
   - Reference actual code: "Add more items like {example}", "Balance the {thing you saw}"
   - Provide 2-3 suggested goals as options

   **Question 2: Iterations**
   - Options: 3 (quick), 5 (medium), 10 (thorough)

   **Question 3: Agent Feedback**
   - **Auto (Recommended)**: Spawn agents to review changes each iteration (Claude decides what kind based on goal)
   - **None**: No agent feedback between iterations

   Note: User can also type a custom agent description like "security expert" or "game designer"

5. **Run the setup**:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-start.sh --dir DIR --goal "GOAL" --max-iterations N --feedback-agent AGENT
   ```
   Where AGENT is "auto", a custom description, or omitted for none.

---

The loop runs via a **Stop hook** and iterates until `--max-iterations` is reached.

Cancel anytime with: `/stop`

After setup, respond with a short progress note (or just `ok`). The loop will take over from here.
