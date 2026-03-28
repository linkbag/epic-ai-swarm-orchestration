# Work Log: claude-swarm-maxconcurrent
## Task: swarm-maxconcurrent (SwarmV3)
## Branch: feat/swarm-maxconcurrent
---

### [Step 1] Read existing scripts
- **Files changed:** None
- **What:** Read swarm.conf, spawn-batch.sh, spawn-agent.sh, integration-watcher.sh
- **Why:** Understand current state before modifying
- **Decisions:** Session names are ${AGENT}-${TASK_ID} (deterministic). integration-watcher uses tmux session existence check in all_done() — non-existent sessions considered "done", so queued sessions can't be pre-passed.
- **Issues found:** integration-watcher.sh has MAX_PARALLEL=10 hardcoded limit that would block large batches.

### Decision: Queue-watcher starts integration-watcher (not spawn-batch)
- **Choice:** queue-watcher.sh is responsible for starting integration-watcher once queue is drained
- **Why:** integration-watcher.all_done() considers non-existent tmux sessions as "done". If we pass queued session names to integration-watcher before those sessions are spawned, it would proceed to integration phase prematurely.
- **Alternatives considered:** (A) Pre-create placeholder tmux sessions — too complex and fragile. (B) Modify integration-watcher to wait for sessions to appear — requires significant rewrite. (C) Have spawn-batch start integration-watcher with all sessions — breaks because of "already done" false positive.
- **Impact:** queue-watcher.sh owns the integration-watcher lifecycle for overflow batches. No-overflow batches unchanged.

### [Step 2] Modified swarm.conf
- **Files changed:** scripts/swarm.conf
- **What:** Added SWARM_MAX_CONCURRENT=8
- **Why:** Config-driven concurrent agent limit

### [Step 3] Rewrote spawn-batch.sh
- **Files changed:** scripts/spawn-batch.sh
- **What:** Source swarm.conf → MAX_PARALLEL. Remove MAX_PARALLEL error check. Split tasks into INITIAL_BATCH + QUEUED. Spawn initial batch. Write queue file + start queue-watcher for overflow. Start integration-watcher directly for no-overflow case (identical to original).
- **Why:** Config-driven limit with auto-queue overflow
- **Decisions:** No-overflow path is byte-for-byte identical to original behavior. Queue path writes queue-${BATCH_ID}.json with allSessions (pre-computed) + pending tasks.

### [Step 4] Created queue-watcher.sh
- **Files changed:** scripts/queue-watcher.sh (new)
- **What:** Polls every 60s, counts active tmux sessions, spawns next queued task when slot opens. When queue empty, starts integration-watcher with allSessions. 4-hour timeout.
- **Why:** Auto-spawn overflow tasks as slots free up

### [Step 5] Fixed integration-watcher.sh limit
- **Files changed:** scripts/integration-watcher.sh
- **What:** Changed MAX_PARALLEL=10 to MAX_SESSIONS=50 with updated error message
- **Why:** Need to support total sessions > 10 for overflow batches (e.g. 8 concurrent but 20 total tasks)

### [Step 6] Validated all scripts
- **Files changed:** None
- **What:** bash -n on all 15 .sh scripts in scripts/
- **Build status:** All pass

## Handoff
- **What changed:**
  - `scripts/swarm.conf` — Added `SWARM_MAX_CONCURRENT=8` (new config key for concurrent agent limit)
  - `scripts/spawn-batch.sh` — Sources swarm.conf; uses SWARM_MAX_CONCURRENT as MAX_PARALLEL (default 8); removed "too many tasks" error; splits tasks into initial batch + overflow queue; starts queue-watcher.sh when overflow exists; no-overflow path is byte-for-byte identical to original
  - `scripts/queue-watcher.sh` — New script: polls tmux every 60s, spawns next queued task when slot opens (active < MAX_CONCURRENT), starts integration-watcher once all tasks are spawned, 4-hour timeout
  - `scripts/integration-watcher.sh` — Changed MAX_PARALLEL=10 to MAX_SESSIONS=50 to support large batch totals
- **How to verify:**
  - `bash -n scripts/*.sh` — all pass (15 scripts)
  - Test no-overflow: create tasks.json with ≤8 tasks, run spawn-batch.sh — behavior identical to before
  - Test overflow: create tasks.json with >8 tasks, run spawn-batch.sh — should spawn 8, write queue-${BATCH_ID}.json, start queue-watcher in background
  - Test queue-watcher: `scripts/queue-watcher.sh queue-batch-xyz.json` with a populated queue file
- **Known issues:** No remote configured on this repo — could not push or create PR
- **Integration notes:**
  - SWARM_MAX_CONCURRENT is now the single source of truth for concurrency — update swarm.conf to change the limit
  - queue-watcher.sh starts integration-watcher (not spawn-batch.sh) for overflow batches
  - integration-watcher.sh MAX_SESSIONS raised from 10 to 50; if you need >50 total sessions, update that constant
  - Batch metadata JSON now includes `queueFile` key for overflow batches (instead of `integrationWatcher`)
- **Decisions made:**
  - queue-watcher starts integration-watcher: because integration-watcher.all_done() considers non-existent tmux sessions as "done" — passing future session names would cause premature integration
  - allSessions pre-populated in queue file: both initial and queued session names written at spawn-batch time, so queue-watcher can pass them all to integration-watcher without tracking state
- **Build status:** pass — `bash -n scripts/*.sh` all 15 scripts clean

### Review Round 1
- Verdict: Review passed — reviewer exited cleanly (auto-pass: clean exit, no issues indicated)
