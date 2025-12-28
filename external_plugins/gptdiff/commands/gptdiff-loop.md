---
description: "Start a GPTDiff-powered agent loop on a subdirectory (scaffold + iterate)"
argument-hint: "--dir PATH [--template generic|game-world] [--goal '...'] [--max-iterations N] [--eval-cmd '...'] [--cmd '...'] [--model MODEL] [--overwrite-scaffold]"
allowed-tools: ["Bash"]
---

# GPTDiff Loop

Initialize the loop (this scaffolds the target directory and writes loop state):

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-gptdiff-loop.sh" $ARGUMENTS
```

The loop runs via a **Stop hook**:
- it repeatedly invokes `gptdiff --apply`
- it iterates until `--max-iterations` is reached (or `--cmd` succeeds)

You can cancel anytime:
- `/cancel-gptdiff-loop`

Now respond with a short progress note (or just `ok`). The loop will take over from here.
