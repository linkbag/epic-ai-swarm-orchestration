#!/usr/bin/env bash
# queue-watcher.sh — Auto-spawn queued tasks as concurrent slots free up.
#
# Usage: queue-watcher.sh <queue-file>
#
# Polls every 60s. When active agent sessions < SWARM_MAX_CONCURRENT, spawns the next
# pending task from the queue file. When the queue is empty, starts integration-watcher.sh
# with all sessions (initial + queued). Exits after 4 hours (safety timeout).
#
# Queue file format (JSON):
# {
#   "batchId": "batch-id",
#   "projectDir": "/path/to/project",
#   "description": "batch description",
#   "allSessions": ["claude-task-1", ...],   <- pre-populated with ALL session names
#   "pending": [                              <- tasks not yet spawned
#     {"id": "task-5", "description": "...", "role": "builder", "model": "", "reasoning": "high"}
#   ]
# }

set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SWARM_DIR/swarm.conf" ]] && source "$SWARM_DIR/swarm.conf"
MAX_CONCURRENT="${SWARM_MAX_CONCURRENT:-8}"

QUEUE_FILE="${1:?Usage: queue-watcher.sh <queue-file>}"
[[ -f "$QUEUE_FILE" ]] || { echo "[queue-watcher] Error: queue file not found: $QUEUE_FILE" >&2; exit 1; }

BATCH_ID=$(python3 -c "import json; print(json.load(open('$QUEUE_FILE'))['batchId'])")
PROJECT_DIR=$(python3 -c "import json; print(json.load(open('$QUEUE_FILE'))['projectDir'])")
BATCH_DESC=$(python3 -c "import json; print(json.load(open('$QUEUE_FILE')).get('description', ''))")

LOG_DIR="$SWARM_DIR/logs"
mkdir -p "$LOG_DIR"

SPAWN_AGENT="$SWARM_DIR/spawn-agent.sh"
ENDORSE_SCRIPT="$SWARM_DIR/endorse-task.sh"
INTEGRATION_WATCHER="$SWARM_DIR/integration-watcher.sh"

TIMEOUT_SECS=14400  # 4 hours
START_TIME=$(date +%s)
POLL_INTERVAL=60

echo "[queue-watcher] Batch: $BATCH_ID | Max concurrent: $MAX_CONCURRENT | Queue: $QUEUE_FILE"

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [[ $ELAPSED -gt $TIMEOUT_SECS ]]; then
    echo "[queue-watcher] ⚠️ Timeout after 4h — remaining tasks abandoned." >&2
    exit 1
  fi

  PENDING_COUNT=$(python3 -c "import json; print(len(json.load(open('$QUEUE_FILE')).get('pending', [])))")

  if [[ $PENDING_COUNT -eq 0 ]]; then
    echo "[queue-watcher] Queue empty — all tasks spawned."
    break
  fi

  ACTIVE=$(tmux ls 2>/dev/null | grep -cE "^(claude|codex|gemini)-" || echo 0)

  if [[ $ACTIVE -lt $MAX_CONCURRENT ]]; then
    # Pop next task from queue file
    NEXT_TASK=$(python3 - <<'PY' "$QUEUE_FILE"
import json, sys
queue_file = sys.argv[1]
with open(queue_file, 'r') as f:
    data = json.load(f)
pending = data.get('pending', [])
if not pending:
    print("")
    sys.exit(0)
task = pending.pop(0)
data['pending'] = pending
with open(queue_file, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print('\t'.join([task['id'], task['description'], task['agent'],
                 task.get('model', ''), task.get('reasoning', 'high')]))
PY
    )

    if [[ -n "$NEXT_TASK" ]]; then
      IFS=$'\t' read -r TASK_ID DESCRIPTION ROLE_OR_AGENT MODEL REASONING <<< "$NEXT_TASK"

      ENDORSE_FILE="$SWARM_DIR/endorsements/${TASK_ID}.endorsed"
      if [[ ! -f "$ENDORSE_FILE" ]]; then
        "$ENDORSE_SCRIPT" --batch "$TASK_ID" >/dev/null
      fi

      # Pass role-or-agent to spawn-agent.sh which resolves from duty table
      "$SPAWN_AGENT" "$PROJECT_DIR" "$TASK_ID" "$DESCRIPTION" "$ROLE_OR_AGENT" "$MODEL" "$REASONING"

      echo "[queue-watcher] ✅ Spawned: ${ROLE_OR_AGENT}-${TASK_ID} ($((ACTIVE + 1))/$MAX_CONCURRENT active, $((PENDING_COUNT - 1)) remaining)"
    fi
  else
    echo "[queue-watcher] ⏳ Waiting for slot ($ACTIVE/$MAX_CONCURRENT active, $PENDING_COUNT queued)..."
  fi

  sleep $POLL_INTERVAL
done

# All tasks spawned — read allSessions and start integration watcher
mapfile -t ALL_SESSIONS < <(python3 -c "
import json
d = json.load(open('$QUEUE_FILE'))
for s in d.get('allSessions', []):
    print(s)
")

if [[ ${#ALL_SESSIONS[@]} -lt 1 ]]; then
  echo "[queue-watcher] Error: no sessions found in queue file" >&2
  exit 1
fi

INTEG_LOG="$LOG_DIR/integration-${BATCH_ID}-watcher.log"
echo "[queue-watcher] 🔗 Starting integration watcher for ${#ALL_SESSIONS[@]} sessions: ${ALL_SESSIONS[*]}"

nohup "$INTEGRATION_WATCHER" "$PROJECT_DIR" "$BATCH_DESC" "${ALL_SESSIONS[@]}" >> "$INTEG_LOG" 2>&1 &
INTEG_PID=$!
echo "[queue-watcher] Integration watcher PID: $INTEG_PID | Log: $INTEG_LOG"
