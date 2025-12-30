---
description: "Start a GPTDiff-powered agent loop on directories or files"
argument-hint: "<goal> | --dir PATH --goal '...' [--feedback-cmd CMD] [--max-iterations N]"
allowed-tools: ["Bash", "Glob", "Read", "AskUserQuestion", "Task"]
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

2. **Spawn an agent for project analysis**:
   Use the Task tool with `subagent_type="Explore"` to analyze the project.

   Prompt the agent to:
   - Explore the project structure and identify the domain (game, web app, API, CLI tool, library, etc.)
   - Find directories/files most relevant to the goal: "$ARGUMENTS"
   - Recommend 1-3 target directories or files for the improvement loop
   - Return a JSON-like summary: `{targets: [...], rationale: "..."}`

3. **Ask about configuration** using AskUserQuestion with MULTIPLE questions:

   Ask these in a SINGLE AskUserQuestion call with multiple questions:

   **Question 1: Iterations**
   - Show what directories/files you found
   - Options: 3 (quick), 5 (medium), 10 (thorough)

   **Question 2: Agent Feedback**
   - **Auto (Recommended)**: Claude picks an appropriate agent each iteration
   - **None**: No agent feedback between iterations

4. **Run the setup**:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-start.sh --dir DIR [--dir DIR2] --goal "THE_GOAL_FROM_ARGUMENTS" --max-iterations N --feedback-agent AGENT
   ```
   Where AGENT is "auto" or omitted for none.

## If NO arguments provided (empty $ARGUMENTS):

Full interactive mode:

1. **Discover the project structure**:
   ```bash
   ls -d */ 2>/dev/null | head -20
   ls package.json pyproject.toml Makefile Cargo.toml go.mod 2>/dev/null || true
   ```

2. **Spawn an agent for comprehensive project analysis**:
   Use the Task tool with `subagent_type="Explore"` to analyze the entire project.

   Prompt the agent to:
   - Explore the full project structure
   - Identify the project domain (game, web app, API, CLI tool, library, data pipeline, etc.)
   - Read key files to understand the codebase
   - Recommend target directories/files for improvement
   - Suggest 2-3 specific, actionable goals based on what it finds
   - Return a summary: `{domain: "...", targets: [...], suggested_goals: [...], rationale: "..."}`

3. **Ask about configuration** using AskUserQuestion with MULTIPLE questions:

   Ask these in a SINGLE AskUserQuestion call with multiple questions:

   **Question 1: Target directories/files**
   - Pre-select the agent's suggested targets as defaults
   - Offer other directories as additional options

   **Question 2: Goal**
   - Use the agent's suggested goals as the main options
   - Be specific: if you see enemies.ts with 3 enemies, suggest "Add 2-3 new enemy types"
   - Be directional: "Add more X", "Improve Y", "Expand Z", "Polish W"
   - Reference actual code: "Add more items like {example}", "Balance the {thing you saw}"

   **Question 3: Iterations**
   - Options: 3 (quick), 5 (medium), 10 (thorough)

   **Question 4: Agent Feedback**
   - **Auto (Recommended)**: Claude picks an appropriate agent each iteration
   - **None**: No agent feedback between iterations

4. **Run the setup**:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-start.sh --dir DIR --goal "GOAL" --max-iterations N --feedback-agent AGENT
   ```
   Where AGENT is "auto" or omitted for none.

---

The loop runs via a **Stop hook** and iterates until `--max-iterations` is reached.

Cancel anytime with: `/stop`

After setup, respond with a short progress note (or just `ok`). The loop will take over from here.
