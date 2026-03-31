# Tools Reference — Command Cheatsheet

## Pre-Flight Checks

Before spawning any agent:
```bash
# 1. Verify model availability
bash assess-models.sh --dry-run

# 2. Check duty table assignments
python3 -c "import json; d=json.load(open('duty-table.json')); [print(f'  {r}: {e[\"agent\"]}/{e[\"model\"]}') for r,e in d['dutyTable'].items()]"

# 3. Verify tmux is available
tmux -V

# 4. Check active agents (if any)
tmux ls 2>/dev/null || echo "No active agents"

# 5. Verify git remote
cd <project-dir> && git remote -v
```

## spawn-agent.sh

```
Usage: spawn-agent.sh <project-dir> <task-id> <description> [role-or-agent] [model] [reasoning]

  project-dir:   absolute path to the project root
  task-id:       unique identifier (branch: feat/<task-id>, session: <agent>-<task-id>)
  description:   task prompt text or path to a .md prompt file
  role-or-agent: architect | builder | reviewer | integrator | claude | codex | gemini
                 (default: builder)
  model:         model override (default: resolved from duty table)
  reasoning:     low | medium | high (default: high)
```

**Examples:**
```bash
# Role-based (recommended — uses duty table)
spawn-agent.sh ~/project fix-bug "Fix the null pointer in auth.py" builder
spawn-agent.sh ~/project design-api /tmp/prompt.md architect

# Direct agent (bypasses duty table)
spawn-agent.sh ~/project fix-bug "Fix it" claude claude-opus-4-6 high
```

## spawn-batch.sh

```
Usage: spawn-batch.sh <project-dir> <batch-id> <batch-description> <tasks-json>
```

**tasks.json format:**
```json
[
  {"id": "task-1", "description": "...", "role": "builder", "reasoning": "high"},
  {"id": "task-2", "description": "...", "role": "architect"},
  {"id": "task-3", "description": "...", "agent": "claude", "model": "claude-sonnet-4-6"}
]
```

Fields:
- `id` (required): unique task identifier
- `description` (required): prompt text
- `role` (recommended): architect | builder | reviewer | integrator → resolved from duty table
- `agent` + `model` (optional): direct override, bypasses duty table
- `reasoning` (optional): low | medium | high (default: high)

## assess-models.sh

```bash
bash assess-models.sh              # Full assessment + update duty table
bash assess-models.sh --dry-run    # Test models without updating
bash assess-models.sh --fallback   # Force all-Claude fallback table
```

## model-fallback.sh

```bash
bash model-fallback.sh <role> <failed-agent> <failed-model>
# Output: agent|model|nonInteractiveCmd
# Example:
bash model-fallback.sh builder codex gpt-5.3-codex
# → claude|claude-sonnet-4-6|claude --model claude-sonnet-4-6 --permission-mode bypassPermissions --print
```

## Monitoring

```bash
tmux ls                                           # Active sessions
cat pending-notifications.txt                      # Unread alerts
bash pulse-check.sh                               # Detect stuck agents
bash check-agents.sh                              # Agent status report
bash daily-standup.sh                             # Daily summary
cat duty-table.json | python3 -m json.tool        # Current assignments
tail -20 logs/<session>.log                        # Agent output log
```

## Cleanup

```bash
bash cleanup.sh           # Remove completed worktrees + old logs
```

## Configuration: swarm.conf

```bash
SWARM_NOTIFY_TARGET="<telegram-user-id>"   # Notification recipient
SWARM_NOTIFY_CHANNEL="telegram"            # Channel (telegram/slack/etc)
SWARM_MAX_CONCURRENT=8                     # Max parallel agents
```
