---
name: epic-ai-swarm-orchestration
description: Multi-agent AI swarm orchestration system for parallel coding tasks. Use when spawning multiple AI coding agents (Claude, Codex, Gemini) to work in parallel on a project with automatic tmux tracking, endorsement gates, integration merging, Telegram notifications, review chains, and completion watchers. Triggers on multi-agent work, parallel coding tasks, swarm orchestration, batch spawning, agent monitoring, or when 2+ coding tasks should run simultaneously with coordinated integration.
---

# Epic AI Swarm Orchestration v3.1

Multi-agent coding orchestration: plan → endorse → spawn → monitor → review → integrate → ship.

## Core Workflow

1. **Plan** — Break work into parallel tasks, present plan to user for endorsement
2. **Endorse** — `endorse-task.sh <task-id>` (or auto-endorsed via `spawn-batch.sh`)
3. **Spawn** — `spawn-batch.sh` (multi) or `spawn-agent.sh` (single)
4. **Monitor** — Auto: tmux sessions, `notify-on-complete.sh` watchers, `pulse-check.sh`
5. **Review** — Auto: reviewer agent spawns on completion, max 3 fix rounds
6. **Integrate** — Auto: `integration-watcher.sh` merges all branches, resolves conflicts
7. **Ship** — Auto-merge to main, cleanup worktrees, notify user

## Script Reference

### Primary (use these)

| Script | Purpose | When |
|--------|---------|------|
| `spawn-batch.sh` | Spawn N agents + auto-integration | **Multi-agent work** |
| `spawn-agent.sh` | Spawn single agent | Single tasks |
| `endorse-task.sh` | Endorse a task | Before spawning |
| `check-agents.sh` | Check tmux status | Quick status |
| `cleanup.sh` | Remove worktrees + branches | Post-merge |

### Usage

```bash
# 1. Write prompts
cat > /tmp/prompt-task1.md << 'EOF'
... task description ...
EOF

# 2. Create tasks JSON
cat > /tmp/tasks.json << 'EOF'
[
  {"id": "task-1", "description": "/tmp/prompt-task1.md", "agent": "claude", "model": "claude-sonnet-4-6"},
  {"id": "task-2", "description": "/tmp/prompt-task2.md", "agent": "claude", "model": "claude-sonnet-4-6"}
]
EOF

# 3. Endorse + spawn
cd path/to/swarm/scripts
bash endorse-task.sh task-1
bash endorse-task.sh task-2
bash spawn-batch.sh "/path/to/project" "batch-id" "Description" /tmp/tasks.json
```

#### spawn-agent.sh

```
spawn-agent.sh <project-dir> <task-id> <description-or-prompt-file> [agent] [model] [reasoning]
```

- `project-dir`: Absolute path to project root
- `task-id`: Unique ID (used for branch name + tmux session)
- `description`: Task prompt text or path to `.md` prompt file
- `agent`: `claude` | `codex` | `gemini` (default: `claude`)
- `model`: Model override (default: per duty table)
- `reasoning`: `low` | `medium` | `high` (default: `high`)

### Supporting Scripts

| Script | Purpose |
|--------|---------|
| `integration-watcher.sh` | Poll + auto-merge (called by spawn-batch) |
| `notify-on-complete.sh` | Per-agent watcher (called by spawn-agent) |
| `start-integration.sh` | Manual integration start |
| `pulse-check.sh` | Detect stuck agents |
| `queue-watcher.sh` | Process inbox queue |
| `inbox-add.sh` | Add task to inbox |
| `inbox-list.sh` | List queued tasks |
| `assess-models.sh` | Weekly model rotation |
| `deploy-notify.sh` | CI/CD build notifications |
| `esr-log.sh` | Log to ESR/work history |
| `daily-standup.sh` | Generate standup summary |
| `cleanup.sh` | Post-merge cleanup |

## Setup

1. Copy `scripts/` to your workspace (e.g., `~/workspace/swarm/`)
2. Copy `duty-table.template.json` → `duty-table.json` and customize
3. Ensure `tmux`, `git`, `gh` CLI, and at least one coding agent CLI are installed
4. For notifications: configure OpenClaw with Telegram/Discord

### Dependencies

- `bash` 4+ (macOS: install via Homebrew, ships with Linux)
- `tmux` (all platforms: `brew install tmux` / `apt install tmux`)
- `git` + `gh` CLI (for PR creation and merging)
- `jq` (JSON processing: `brew install jq` / `apt install jq`)
- At least one coding agent: `claude` (Claude Code), `codex`, or `gemini`
- Optional: `openclaw` (for Telegram/Discord notifications)

### macOS Notes

- macOS ships with bash 3.x; install bash 5+ via `brew install bash`
- Use `brew install gnu-sed` and alias `sed=gsed` if scripts use GNU sed features
- `tmux` works identically on macOS and Linux

## Configuration

### duty-table.json

Maps roles to agents/models:

```json
{
  "dutyTable": {
    "architect": {"agent": "claude", "model": "claude-opus-4-6"},
    "builder":   {"agent": "claude", "model": "claude-sonnet-4-6"},
    "reviewer":  {"agent": "claude", "model": "claude-sonnet-4-6"},
    "integrator":{"agent": "claude", "model": "claude-opus-4-6"}
  }
}
```

### Endorsement System

Every task requires endorsement before spawning (safety gate):
- `spawn-batch.sh` auto-endorses all tasks in the batch
- Manual: `bash endorse-task.sh <task-id>`
- 30-second cooldown between endorsement and spawn

## Hard Rules

1. **Always endorse before spawning** — no endorsement = no spawn
2. **Use spawn-batch.sh for 2+ tasks** — it starts the integration watcher
3. **Never use bare `claude --print` in background** — bypasses tmux, notifications, everything
4. **Let notify-on-complete.sh handle notifications** — don't add `openclaw system event` to prompts
