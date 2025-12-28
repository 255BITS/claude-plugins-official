# Game World Interface Contract (Template)

This directory is a **game-content workspace** intended for iterative improvement loops.

Nothing in here is tied to a specific engine. The goal is to define a *clear contract* so agent loops can:

- create new items
- refine item identity and clarity
- model interactions (synergies/counters/triggers/effects)
- rebalance numbers and progression

If your game already has its own formats, update this file to match your reality.

## Philosophy

- **Data-driven content wins.** Keep “design surface area” explicit in files.
- **Small diffs.** Prefer incremental improvements per iteration.
- **Identity + balance.** Items should be distinct *and* not break the curve.
- **Readable + toolable.** Prefer JSON for validation, but YAML/Markdown is fine if consistent.

## Recommended layout (choose what fits)

You can keep everything flat, or adopt a structure like:

```
./
  INTERFACE.md
  RUBRIC.md
  items/            # item defs (optional)
  interactions/     # interaction defs (optional)
  balance/          # curves, tier tables, tuning notes (optional)
  lore/             # flavor text (optional)
```

If you don’t want subfolders, you can keep `*.json` / `*.yaml` files at the top-level.

## Entity types

### 1) Item

Items are playable “verbs” or “tools” in your game.

**Minimum recommended fields:**

- `id` (string, stable, lowercase snake/kebab)
- `name` (player-facing)
- `tier` (number or named tier)
- `rarity` (common/uncommon/rare/epic/etc)
- `tags` (array of strings: weapon, fire, healing, crafting, etc)
- `description` (1–3 lines, player-facing)
- `stats` (object; game-specific keys)
- `effects` (array; can be empty)
- `constraints` (object; optional)

**Example (JSON):**

```json
{
  "id": "iron_sword",
  "name": "Iron Sword",
  "tier": 2,
  "rarity": "common",
  "tags": ["weapon", "melee"],
  "description": "Reliable early-game blade. Simple, steady damage.",
  "stats": { "damage": 12, "attack_speed": 1.0, "stamina_cost": 2 },
  "effects": [
    { "type": "bleed", "chance": 0.08, "duration_s": 3, "dps": 1.0 }
  ],
  "constraints": { "requires_level": 3 }
}
```

### 2) Effect

Effects describe outcomes that can be attached to items or interactions.

**Example:**

```json
{ "type": "burn", "duration_s": 4, "dps": 2.5 }
```

### 3) Interaction

Interactions describe synergies/counters and event-driven behavior.

**Minimum recommended fields:**
- `id`
- `trigger` (event + conditions)
- `effects` (what happens)
- `notes` (optional design intent)

**Example:**

```json
{
  "id": "freeze_then_shatter_bonus",
  "trigger": { "event": "on_hit", "target_has_status": "frozen" },
  "effects": [
    { "type": "damage_multiplier", "value": 1.25 },
    { "type": "consume_status", "status": "frozen" }
  ],
  "notes": "Rewards setup + timing; prevents degenerate perma-freeze."
}
```

## Balancing rules (guidance)

These are defaults — update to match your game:

- **Power curve:** items within a tier should have comparable “power budget”
- **Identity:** every item should have a reason to exist (role, niche, combo)
- **Counters:** strong strategies should have plausible counters
- **Avoid degeneracy:** no infinite loops, no strictly-dominant items
- **Clarity:** description + tags should match actual behavior

## What an agent loop is allowed to do here

An improvement loop may:

- add new item files
- revise item stats + descriptions
- add interactions to create synergy/counterplay
- add/extend balance notes to keep the curve coherent
- remove or merge items *only if* they are redundant and replacement is documented

An agent loop should NOT:

- delete lots of content just to “reduce complexity”
- break schema/format consistency
- rename ids casually (id stability matters)

## Human review checkpoints

After a loop run, validate:

- Are new items *interesting*?
- Any broken formats?
- Any obvious power creep?
- Any redundancy?
- Does the content align with RUBRIC.md?

```

This changeset is from the following instructions:
