# AI Swarm v3.0 — Improvement Plan

**Created:** 2026-03-28
**Status:** Draft — awaiting WB endorsement
**Based on:** Audit of current swarm v2.0 + comparison with arminnaimi/agent-team-orchestration

---

## Current System Audit Summary

### What's Working Well (KEEP — non-negotiable)
- ✅ Research + planning phase (Opus architect)
- ✅ Endorsement gate (plan → WB approval → spawn)
- ✅ Subteam sandboxes (git worktrees + tmux isolation)
- ✅ Review+fix chains (notify-on-complete.sh, max 3 loops)
- ✅ Integration watcher (auto-merge + cross-team review)
- ✅ Work logs + ESR persistence (docs/history/ + Obsidian sync)
- ✅ Multi-vendor duty table with auto-assessment + fallback-swap
- ✅ Telegram notifications at every milestone
- ✅ Stuck detection + auto-kill (pulse-check.sh)
- ✅ CI/CD build notifications (deploy-notify.sh)

### Issues Found in Audit

1. **active-tasks.json has 61 "running" tasks that are actually done** — no script updates status to "done" when agents complete. The `status` field is write-once at spawn time and never touched again. This is the #1 data integrity problem.

2. **No task queuing** — if you want to do 12 tasks but maxConcurrent is 8, there's no way to queue the remaining 4. You have to manually batch.

3. **spawn-batch.sh hardcodes MAX_PARALLEL=10** — no config-driven limit. Also no queuing for overflow.

4. **No structured handoff template** — agents get work log instructions but no standardized handoff format. Reviewers have to parse free-form text.

5. **No escalation path** — stuck agents get killed by pulse-check.sh, but there's no "agent writes a blocker file" → "orchestrator gets actionable notification" flow. Agents just silently struggle until timeout.

6. **No inbox/task queue** — every batch is a one-shot "think of everything now" exercise. No accumulator for "do later" tasks.

7. **No decision logging** — architectural choices made by agents during builds are only captured in commit messages (if at all).

8. **Stale data accumulation** — endorsement files, old worklogs in /tmp, pulse-state entries for dead sessions never get cleaned up.

9. **swarm.conf is minimal** — maxConcurrent, review focus rotation, and other tunables don't exist as config.

---

## Improvement Plan (9 items, priority-ordered)

### 1. Task State Machine — Fix active-tasks.json (HIGH / MEDIUM effort)
**Problem:** 61 tasks show "running" that are actually done. No script updates task status.
**Solution:**
- Add state transitions to active-tasks.json: `pending → running → review → done | failed`
- `notify-on-complete.sh`: update status to "review" when builder finishes, "done" when review passes, "failed" on max loops
- `integration-watcher.sh`: update status to "done" after successful integration
- `pulse-check.sh`: update status to "failed" when killing stuck agents
- Add `completedAt`, `failedAt`, `failReason` fields
- Add `update-task-status.sh` helper that other scripts call (single place for state transitions)
- **Cleanup:** Write a one-time migration to mark all 61 orphaned "running" tasks as "done" (they're all completed)

### 2. Structured Handoff Template (HIGH / LOW effort)
**Problem:** Reviewers parse free-form work logs. Quality varies.
**Solution:**
- Standardize the work log summary section in `spawn-agent.sh` prompt template to include explicit fields:
  ```
  ## Handoff
  - **What changed:** (file list with brief descriptions)
  - **How to verify:** (test commands or manual checks)
  - **Known issues:** (anything incomplete or risky)
  - **Integration notes:** (what other agents/integrator should watch for)
  - **Decisions made:** (any architectural choices with reasoning)
  ```
- Reviewer prompt in `notify-on-complete.sh` explicitly references these sections
- This is a prompt-only change — zero script logic changes

### 3. Task Inbox Queue (HIGH / LOW effort)
**Problem:** Every batch requires thinking of all tasks at once. No accumulator.
**Solution:**
- Create `~/workspace/swarm/inbox.json` — array of task proposals:
  ```json
  [
    {"id": "ll-fix-xyz", "project": "LinguaLens", "description": "Fix freeze on rotate", "priority": "high", "addedAt": "2026-03-28T10:00:00"},
    {"id": "gc-new-feature", "project": "GradChoice", "description": "Add export button", "priority": "medium", "addedAt": "2026-03-28T10:05:00"}
  ]
  ```
- Add `inbox-add.sh <project> <id> <description> [priority]` — quick CLI to queue tasks
- During planning phase, I read inbox.json and propose batches from queued items
- After endorsement+spawn, items move from inbox to active-tasks.json
- During heartbeats, I can report: "You have X items in the inbox"

### 4. Escalation Protocol — blockers.txt (HIGH / LOW effort)
**Problem:** Agents get stuck and are silently killed. No structured blocker reporting.
**Solution:**
- Add to the agent prompt template:
  ```
  ## ⚠️ IF YOU GET BLOCKED:
  1. Write the blocker to /tmp/blockers-{task-id}.txt with: what's blocked, why, what you need
  2. Continue with any other work you can do
  3. Do NOT silently retry the same thing for 10+ minutes
  ```
- `pulse-check.sh`: check for `/tmp/blockers-*.txt` files, include content in Telegram notification
- This gives WB (and me during heartbeats) actionable blocker info instead of "agent was stuck, killed it"

### 5. MaxConcurrent Config + Auto-Queue (MEDIUM / MEDIUM effort)
**Problem:** spawn-batch.sh hardcodes MAX_PARALLEL=10. No overflow queuing.
**Solution:**
- Add to `swarm.conf`: `SWARM_MAX_CONCURRENT=8`
- `spawn-batch.sh`: read config, spawn up to maxConcurrent, write remainder to a queue file
- Add `queue-watcher.sh`: polls tmux sessions, when a slot opens (agent finishes), auto-spawns next queued task
- `queue-watcher.sh` auto-endorses queued tasks (they were already endorsed as part of the batch)
- Integration watcher waits for ALL tasks (spawned + queued) before integrating

### 6. Daily Standup Cron (MEDIUM / LOW effort)
**Problem:** No automated daily summary. WB has to ask or check manually.
**Solution:**
- Create a cron job (using Sonnet) that runs daily at 09:00 PST:
  1. Read `active-tasks.json` for recently completed/running/failed tasks
  2. Check `inbox.json` for queued items
  3. Check git logs for active projects (last 24h)
  4. Produce a brief standup:
     ```
     🌅 Daily Standup — 2026-03-28
     ✅ Completed yesterday: 3 tasks (LinguaLens PR #87-88, GradChoice deploy)
     🔨 In progress: 0 agents running
     📥 Inbox: 2 tasks queued
     ⚠️ Blocked: none
     📊 Duty table: all models healthy
     ```
  5. Deliver to Telegram

### 7. Decision Logging (MEDIUM / LOW effort)
**Problem:** Architectural choices made by agents are lost.
**Solution:**
- Add to agent prompt template a "Decisions" section in the work log:
  ```
  ### Decisions Made
  - **Decision:** Used WorkManager instead of AlarmManager
  - **Why:** More reliable for periodic tasks on API 23+
  - **Alternatives considered:** AlarmManager (simpler but less reliable)
  ```
- Integration watcher collects these from work logs and appends to `<project>/docs/decisions/YYYY-MM-DD.md`
- Low effort — prompt template change + a few lines in integration-watcher.sh

### 8. Stale Data Cleanup (LOW / LOW effort)
**Problem:** Endorsement files, /tmp worklogs, pulse-state entries accumulate forever.
**Solution:**
- Add `cleanup.sh` that runs weekly (via heartbeat or cron):
  - Remove endorsement files older than 7 days
  - Remove /tmp/worklog-*, /tmp/review-*, /tmp/blockers-* older than 3 days
  - Prune pulse-state.json entries for sessions that no longer exist
  - Archive completed tasks from active-tasks.json older than 30 days to `archived-tasks.json`
- Keeps the system lean without losing historical data

### 9. Enhanced Plan Format (LOW / LOW effort)
**Problem:** Plan tables show task/agent/model but not priority or time estimates.
**Solution:**
- Update ROLE.md plan template to:
  ```
  | # | Task ID | Description | Priority | Est. | Agent | Model |
  |---|---------|-------------|----------|------|-------|-------|
  | 1 | ll-fix-xyz | Fix freeze bug | 🔴 High | ~10m | claude | sonnet |
  | 2 | gc-export | Add export btn | 🟡 Med | ~20m | claude | sonnet |
  ```
- Helps WB make better endorsement decisions
- Pure documentation change

---

## Implementation Order

**Phase 1 — Quick Wins (can do today, ~1-2 hours total):**
- Item 2: Structured handoff template (prompt changes only)
- Item 3: Inbox queue (new file + simple script)
- Item 4: Escalation protocol (prompt + pulse-check tweak)
- Item 7: Decision logging (prompt template addition)
- Item 9: Enhanced plan format (ROLE.md update)

**Phase 2 — Core Infrastructure (~2-3 hours):**
- Item 1: Task state machine (touches spawn-agent, notify-on-complete, integration-watcher, pulse-check + migration script)
- Item 5: MaxConcurrent + auto-queue (new queue-watcher.sh + spawn-batch changes)

**Phase 3 — Automation (~1 hour):**
- Item 6: Daily standup cron
- Item 8: Stale data cleanup

---

## What We're NOT Changing
- Core 3-phase workflow (Plan → Build+Review → Ship)
- Endorsement gate (always require WB approval)
- tmux-based sandboxing
- Git worktree isolation
- Telegram notification pipeline
- Multi-vendor duty table + fallback-swap
- ESR + work log persistence
- spawn-agent.sh / spawn-batch.sh as the ONLY entry points (no bare claude --print)
