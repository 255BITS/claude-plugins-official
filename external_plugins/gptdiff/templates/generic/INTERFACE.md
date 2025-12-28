# Domain Workspace Interface Contract (Generic Template)

This directory is intended to be a **focused surface area** for iterative GPTDiff loops.

The purpose of this file is to define a **stable contract** so an agent can repeatedly improve
the same domain without guessing what “good” means.

You should edit this document to match your domain (game items, encounter tables, NPC dialog, quests, UI copy, etc.).

## Principles

- **Stable ids and names** beat clever refactors.
- **Small diffs** are easier to review and keep coherent.
- **Make intent explicit** (docs + comments + examples).
- **Prefer structured data** when validation matters (JSON/YAML), otherwise Markdown is fine.

## Recommended conventions

### Files

- Keep each “entity” small and self-contained.
- Prefer one entity per file when it helps merge/review.
- Avoid enormous single files that are hard to diff.

### Identity

- If you use ids, keep them stable.
- If you rename, provide a mapping or note (avoid breaking downstream code).

### Validation (optional but recommended)

If you have a validator, linter, test, or simulator, define it here so loops can use it:

- What command validates this directory?
- What does “pass” mean?
- Where do failures show up?

Example:

```
Validation command: python3 tools/validate_content.py
Pass condition: exit code 0, no warnings about missing required fields
```

## What the agent loop may do

The loop may:

- add new files/entities following the conventions here
- refine existing files for clarity and consistency
- reorganize *lightly* if it improves structure (avoid broad churn)
- update docs to match reality

The loop should NOT:

- delete lots of content to “simplify”
- change ids casually
- introduce inconsistent formats
- touch unrelated areas outside this directory (keep scope tight)

## Success criteria

Define what “better” means in this directory:

- Consistency?
- Variety?
- Balance?
- Coverage?
- Clarity?
- Fewer validation warnings?

Write that criteria here, then use it in loop goals.
