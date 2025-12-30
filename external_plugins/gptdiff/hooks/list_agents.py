#!/usr/bin/env python3
"""
List available Claude Code agents from plugins directories.

Outputs JSON with agent names, descriptions, and full prompts.
"""

import os
import sys
import json
import re
from pathlib import Path


def parse_agent_file(filepath: Path) -> dict | None:
    """Parse a markdown agent file and extract frontmatter + body."""
    try:
        content = filepath.read_text()
    except Exception:
        return None

    # Match YAML frontmatter between --- markers
    match = re.match(r'^---\n(.*?)\n---\n(.*)$', content, re.DOTALL)
    if not match:
        return None

    frontmatter_text = match.group(1)
    body = match.group(2).strip()

    # Parse simple YAML (name, description, tools, model, color)
    agent = {'prompt': body}
    for line in frontmatter_text.split('\n'):
        if ':' in line:
            key, value = line.split(':', 1)
            key = key.strip()
            value = value.strip()
            # Remove quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            agent[key] = value

    # Must have at least a name
    if 'name' not in agent:
        agent['name'] = filepath.stem

    return agent


def find_agents(search_paths: list[str]) -> list[dict]:
    """Find all agent files in the given search paths."""
    agents = []
    seen_names = set()

    for search_path in search_paths:
        path = Path(search_path)
        if not path.exists():
            continue

        # Look for agents in */agents/*.md pattern
        for agents_dir in path.glob('*/agents'):
            if not agents_dir.is_dir():
                continue
            for agent_file in agents_dir.glob('*.md'):
                agent = parse_agent_file(agent_file)
                if agent and agent['name'] not in seen_names:
                    agent['source'] = str(agent_file)
                    agents.append(agent)
                    seen_names.add(agent['name'])

        # Also look for agents directly in agents/ subdirectory
        agents_subdir = path / 'agents'
        if agents_subdir.is_dir():
            for agent_file in agents_subdir.glob('*.md'):
                agent = parse_agent_file(agent_file)
                if agent and agent['name'] not in seen_names:
                    agent['source'] = str(agent_file)
                    agents.append(agent)
                    seen_names.add(agent['name'])

    return sorted(agents, key=lambda a: a['name'])


def main():
    import argparse
    parser = argparse.ArgumentParser(description='List available Claude Code agents')
    parser.add_argument('--plugins-dir', action='append', default=[],
                        help='Directory containing plugins with agents (can specify multiple)')
    parser.add_argument('--list-names', action='store_true',
                        help='Just list agent names, one per line')
    parser.add_argument('--catalog', action='store_true',
                        help='Output a human-readable catalog with names and descriptions')
    parser.add_argument('--agent', type=str,
                        help='Get full details for a specific agent by name')
    parser.add_argument('--json', action='store_true',
                        help='Output as JSON')
    args = parser.parse_args()

    # Default search paths
    search_paths = args.plugins_dir
    if not search_paths:
        # Try to find plugins directory relative to this script
        script_dir = Path(__file__).parent
        # Look for common plugin locations
        potential_paths = [
            script_dir.parent.parent.parent / 'plugins',  # ../../../plugins
            Path.home() / '.claude' / 'plugins',
            Path('/usr/local/share/claude-code/plugins'),
        ]
        search_paths = [str(p) for p in potential_paths if p.exists()]

    agents = find_agents(search_paths)

    if args.agent:
        # Find specific agent
        for agent in agents:
            if agent['name'] == args.agent:
                if args.json:
                    print(json.dumps(agent, indent=2))
                else:
                    print(agent.get('prompt', ''))
                return 0
        print(f"Agent not found: {args.agent}", file=sys.stderr)
        return 1

    if args.list_names:
        for agent in agents:
            print(agent['name'])
        return 0

    if args.catalog:
        for agent in agents:
            desc = agent.get('description', 'No description')
            # Truncate long descriptions
            if len(desc) > 120:
                desc = desc[:117] + '...'
            print(f"- **{agent['name']}**: {desc}")
        return 0

    # Default: output JSON
    if args.json or True:  # Always JSON by default
        output = []
        for agent in agents:
            output.append({
                'name': agent['name'],
                'description': agent.get('description', ''),
                'model': agent.get('model', 'inherit'),
                'prompt': agent.get('prompt', ''),
                'source': agent.get('source', ''),
            })
        print(json.dumps(output, indent=2))

    return 0


if __name__ == '__main__':
    sys.exit(main())
