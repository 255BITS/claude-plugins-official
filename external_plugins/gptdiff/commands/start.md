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

The user provided a goal directly. **YOU MUST spawn an agent to analyze the project.**

1. **REQUIRED: Spawn an agent for project analysis FIRST**:

   Look at your available agents (from your system prompt's Task tool section).
   Pick the one best suited for analyzing a project with goal: "$ARGUMENTS"

   Use the Task tool IMMEDIATELY with that agent's name as `subagent_type`.

   Prompt the agent:
   ```
   Analyze this project for the goal: "$ARGUMENTS"

   1. Explore the project structure - what kind of project is this?
   2. Identify the domain (game, web app, API, CLI tool, library, etc.)
   3. Find directories/files most relevant to the goal
   4. Recommend 1-3 target directories or files for an improvement loop

   Return a summary: {domain: "...", targets: [...], rationale: "..."}
   ```

   **DO NOT skip this step. DO NOT ask questions before spawning the agent.**

2. **After the agent returns**, ask about configuration using AskUserQuestion:

   Ask these in a SINGLE AskUserQuestion call with multiple questions:

   **Question 1: Iterations**
   - Show what directories/files you found
   - Options: 3 (quick), 5 (medium), 10 (thorough)

   **Question 2: Agent Feedback**
   - List 2-3 of your available agents that seem most relevant to the goal
   - **Auto**: Claude picks an appropriate agent each iteration
   - **None**: No agent feedback between iterations

4. **Run the setup**:
   ```
   /home/ntc/dev/claude-plugins-official/external_plugins/gptdiff/scripts/setup-gptdiff-start.sh --dir DIR [--dir DIR2] --goal "THE_GOAL_FROM_ARGUMENTS" --max-iterations N --feedback-agent AGENT
   ```
   Where AGENT is "auto" or omitted for none.

## If NO arguments provided (empty $ARGUMENTS):

Full interactive mode. **YOU MUST spawn an agent to analyze the project.**

1. **REQUIRED: Spawn an agent for comprehensive project analysis FIRST**:

   Look at your available agents (from your system prompt's Task tool section).
   Pick the one best suited for exploring and analyzing a codebase.

   Use the Task tool IMMEDIATELY with that agent's name as `subagent_type`.

   Prompt the agent:
   ```
   Analyze this project comprehensively:

   1. Explore the full project structure
   2. Identify the project domain (game, web app, API, CLI tool, library, etc.)
   3. Read key files to understand the codebase
   4. Recommend target directories/files for improvement
   5. Suggest 2-3 specific, actionable goals based on what you find

   Return a summary: {domain: "...", targets: [...], suggested_goals: [...], rationale: "..."}
   ```

   **DO NOT skip this step. DO NOT ask questions before spawning the agent.**

2. **After the agent returns**, ask about configuration using AskUserQuestion:

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
   - List 2-3 of your available agents that seem most relevant to the goal
   - **Auto**: Claude picks an appropriate agent each iteration
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
