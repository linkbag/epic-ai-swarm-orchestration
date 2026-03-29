---
name: epic-ai-swarm-orchestration
description: Production AI swarm orchestration — plan, endorse, spawn parallel agents in tmux sandboxes, auto-review+fix, integrate, and ship. Use when orchestrating multi-agent coding work across projects. Features human endorsement gate, git worktree isolation, multi-vendor duty table with auto-fallback, structured handoff templates, task state machine, inbox queue, escalation protocol, decision logging, concurrent agent limits with auto-queue, daily standup, and stale data cleanup. Supports Claude, Codex, and Gemini agents. NOT for single-file edits or simple questions.
metadata:
  openclaw:
    requires:
      bins: [tmux, git, gh, python3, openclaw]
      optional_bins: [claude, codex, gemini]
---

# Epic AI Swarm Orchestration

Production playbook for running parallel AI coding agents with human oversight, quality gates, and automated integration.

## Prerequisites

### Required CLIs (must be installed and on PATH)
- **tmux** — agent sandboxing (each agent runs in its own tmux session)
- **git** — worktree creation, branching, commits, push
- **gh** — GitHub CLI for PR creation, CI status polling (must be authenticated via `gh auth login`)
- **python3** — JSON manipulation in scripts (no pip packages needed)
- **openclaw** — notification delivery (Telegram/other channels via `openclaw message send`)

### Model CLIs (at least one required, must be authenticated)
- **claude** — Anthropic CLI (primary). Authenticated via `claude` OAuth or API key.
- **codex** — OpenAI Codex CLI (optional). Authenticated via OAuth or API key.
- **gemini** — Google Gemini CLI (optional). Authenticated via Google OAuth.

### Credential Usage
The scripts use **host-authenticated CLIs** — they do not store or manage credentials themselves. Specifically:
- `gh` credentials are used to create PRs and poll CI status
- `openclaw` credentials are used to send Telegram notifications
- Model CLI credentials are used to run agent sessions
- `git push` uses whatever git auth is configured (SSH keys or credential helper)

**If you don't want a script to push/notify**, remove or sandbox the relevant CLI from PATH, or run in a test environment with dummy remotes.

## Quick Start

1. Copy `scripts/` to `~/workspace/swarm/`
2. Edit `scripts/swarm.conf` with your notification target
3. Read [references/workflow.md](references/workflow.md) for the full 3-phase workflow
4. Read [references/tools.md](references/tools.md) for spawn commands and pre-flight checks

## Core Workflow

### Phase 1: PLAN (Architect)
1. Read project context, ESR, codebase
2. Research and pressure-test feasibility
3. Break work into parallel tasks with prompts
4. Present plan table to human → **HOLD until endorsed**

### Phase 2: BUILD + REVIEW (Builder + Reviewer)
5. `spawn-batch.sh` deploys all agents in tmux + worktrees
6. Each agent codes autonomously, maintains structured work log
7. `notify-on-complete.sh` auto-spawns reviewer on completion (max 3 fix loops)

### Phase 3: SHIP (Integrator)
8. `integration-watcher.sh` merges all branches, resolves conflicts
9. Auto-merge to main, clean up worktrees
10. Update ESR + Obsidian, notify human

## Scripts

| Script | Purpose |
|--------|---------|
| `spawn-batch.sh` | Spawn N agents + auto-integration (primary tool) |
| `spawn-agent.sh` | Spawn single agent with full pipeline |
| `notify-on-complete.sh` | Per-agent completion watcher + review chain |
| `integration-watcher.sh` | Cross-team merge + integration review |
| `queue-watcher.sh` | Auto-spawn overflow tasks as slots free up |
| `update-task-status.sh` | Task state transitions (with flock) |
| `pulse-check.sh` | Stuck detection + auto-kill + blocker check |
| `fallback-swap.sh` | Test primary model, swap to fallback if down |
| `inbox-add.sh` / `inbox-list.sh` / `inbox-clear.sh` | Task queue between batches |
| `daily-standup.sh` | Automated daily summary to Telegram |
| `cleanup.sh` | Prune stale endorsements, temp files, pulse state (`--dry-run` supported) |
| `endorse-task.sh` | Create endorsement file for a task |
| `esr-log.sh` | Update Executive Summary Report |
| `deploy-notify.sh` | Poll GitHub Actions + notify on CI result |
| `check-agents.sh` | Quick tmux session status check |
| `migrate-orphaned-tasks.sh` | One-time fix for tasks stuck as "running" |

## Key Features

### Human Endorsement Gate
No agents spawn without explicit human approval. The flow is:
1. Orchestrator presents a plan to the human
2. Human says "yes" / "proceed" / 👍
3. **Only then** does the orchestrator call `spawn-batch.sh`, which creates `.endorsed` files as a record of the verbal approval
4. `spawn-agent.sh` checks for the `.endorsed` file and **refuses to run** without it

The `.endorsed` file creation in `spawn-batch.sh` is a convenience that records the human's verbal approval — it does **not** bypass the human gate. If you call `spawn-agent.sh` directly without endorsement, it will block.

### Auto-Merge Policy
After a branch passes review (builder → reviewer → fix loops), the integration watcher automatically:
- Merges branches to main
- Pushes to the remote
- Updates ESR documentation

**This is by design for teams that want CI-gated auto-merge.** If you prefer manual merges:
- Remove `git push` lines from `integration-watcher.sh`
- Use `gh pr create` without `--auto` and review PRs manually
- Or point git remotes to a staging remote instead of production

### Structured Handoff
Every agent produces a work log with: what changed, how to verify, known issues, integration notes, decisions made, build status. Reviewers and integrators parse these structured sections.

### Task State Machine
Tasks flow through: `pending → running → review → done | failed`. All scripts update `active-tasks.json` via `update-task-status.sh` (with flock for race safety).

### Escalation Protocol
Blocked agents write `/tmp/blockers-{task-id}.txt`. `pulse-check.sh` reads these and notifies via Telegram with actionable context.

### MaxConcurrent + Auto-Queue
`swarm.conf` sets `SWARM_MAX_CONCURRENT=8`. `spawn-batch.sh` spawns up to the limit, queues the rest. `queue-watcher.sh` auto-spawns as slots free up.

### Multi-Vendor Duty Table
`duty-table.json` maps roles (architect/builder/reviewer/integrator) to agents+models with fallback. `fallback-swap.sh` auto-promotes fallback if primary fails.

### Decision Logging
Agents document architectural choices in work logs. `integration-watcher.sh` collects them to `docs/decisions/`.

## Configuration

Edit `scripts/swarm.conf`:
```bash
SWARM_NOTIFY_TARGET="your-telegram-chat-id"
SWARM_NOTIFY_CHANNEL="telegram"
SWARM_MAX_CONCURRENT=8
OBSIDIAN_BASE="/path/to/obsidian/vaults"  # optional
```

## Testing Safely

Before running on production repos:
1. Use `cleanup.sh --dry-run` to preview what cleanup would do
2. Point git remotes to a throwaway repo
3. Set `SWARM_NOTIFY_TARGET` to a test chat
4. Leave `OBSIDIAN_BASE` unset until you've verified behavior

## Reference Files

| File | Read when... |
|------|-------------|
| [workflow.md](references/workflow.md) | Planning swarm work, understanding phases and hard rules |
| [tools.md](references/tools.md) | Spawning agents, writing prompts, resolving conflicts |
