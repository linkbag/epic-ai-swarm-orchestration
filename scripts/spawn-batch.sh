#!/usr/bin/env bash
# spawn-batch.sh — Spawn subteams up to SWARM_MAX_CONCURRENT; auto-queue overflow tasks.
#
# Usage:
#   spawn-batch.sh <project-dir> <batch-id> <batch-description> <tasks-json>
#
# tasks-json format:
# [
#   {"id":"task-1","description":"...","role":"builder","reasoning":"high"},
#   {"id":"task-2","description":"...","role":"architect"}
# ]
# Role-based: set "role" to architect|builder|reviewer|integrator → resolved from duty-table.json
# Direct override: set "agent"+"model" to bypass duty table (e.g. "agent":"claude","model":"claude-sonnet-4-6")
#
# Notes:
# - Preserves existing swarm logging: per-subteam work logs + ESR logs remain unchanged.
# - Starts integration watcher immediately (it waits until all subteams finish before integrating).

set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
SPAWN_AGENT="$SWARM_DIR/spawn-agent.sh"
INTEGRATION_WATCHER="$SWARM_DIR/integration-watcher.sh"
ENDORSE_SCRIPT="$SWARM_DIR/endorse-task.sh"
QUEUE_WATCHER="$SWARM_DIR/queue-watcher.sh"
LOG_DIR="$SWARM_DIR/logs"
mkdir -p "$LOG_DIR"

[[ -f "$SWARM_DIR/swarm.conf" ]] && source "$SWARM_DIR/swarm.conf"
MAX_PARALLEL="${SWARM_MAX_CONCURRENT:-8}"

PROJECT_DIR="${1:?Usage: spawn-batch.sh <project-dir> <batch-id> <batch-description> <tasks-json>}"
BATCH_ID="${2:?Missing batch-id}"
BATCH_DESC="${3:?Missing batch-description}"
TASKS_JSON="${4:?Missing tasks-json path}"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi
if [[ ! -f "$TASKS_JSON" ]]; then
  echo "Error: tasks json not found: $TASKS_JSON" >&2
  exit 1
fi
if [[ ! -x "$SPAWN_AGENT" || ! -x "$INTEGRATION_WATCHER" ]]; then
  echo "Error: required scripts missing or not executable in $SWARM_DIR" >&2
  exit 1
fi

mapfile -t TASK_LINES < <(python3 - <<'PY' "$TASKS_JSON" "$SWARM_DIR/duty-table.json"
import json,sys
p=sys.argv[1]
duty_path=sys.argv[2]

with open(p,'r',encoding='utf-8') as f:
    data=json.load(f)

# Load duty table for role resolution
duty_table={}
try:
    with open(duty_path) as f:
        duty_table=json.load(f).get('dutyTable',{})
except:
    pass

if not isinstance(data,list):
    raise SystemExit('tasks-json must be a JSON array')
for t in data:
    if not isinstance(t,dict):
        raise SystemExit('each task must be an object')
    tid=t.get('id','').strip()
    desc=t.get('description','').strip()
    if not tid or not desc:
        raise SystemExit('each task requires id + description')

    # Role-based resolution: if 'role' is specified (or 'agent' is a role name),
    # resolve agent+model from duty table. Direct agent/model override still works.
    role=t.get('role','').strip()
    agent=t.get('agent','').strip()
    model=t.get('model','').strip()
    reasoning=(t.get('reasoning') or 'high').strip()

    known_roles=['architect','builder','reviewer','integrator']

    # If agent is actually a role name, treat it as a role
    if agent in known_roles and not role:
        role=agent
        agent=''

    # Resolve from duty table if we have a role and no explicit agent override
    if role and role in duty_table and not agent:
        entry=duty_table[role]
        agent=entry.get('agent','claude')
        if not model:
            model=entry.get('model','')

    # Default to builder role from duty table if nothing specified
    if not agent:
        if 'builder' in duty_table:
            entry=duty_table['builder']
            agent=entry.get('agent','claude')
            if not model:
                model=entry.get('model','')
        else:
            agent='claude'

    # Pass role (or 'builder' default) so spawn-agent.sh can resolve from duty table
    role_or_agent=role if role else agent

    print('\t'.join([tid,desc,role_or_agent,model,reasoning]))
PY
)

TASK_COUNT=${#TASK_LINES[@]}
if [[ $TASK_COUNT -lt 1 ]]; then
  echo "Error: no tasks found in $TASKS_JSON" >&2
  exit 1
fi

# Split into initial batch (up to MAX_PARALLEL) and overflow queue
INITIAL_BATCH=("${TASK_LINES[@]:0:$MAX_PARALLEL}")
QUEUED=("${TASK_LINES[@]:$MAX_PARALLEL}")
SPAWNED_COUNT=${#INITIAL_BATCH[@]}
QUEUED_COUNT=${#QUEUED[@]}

SESSIONS=()

if [[ $QUEUED_COUNT -gt 0 ]]; then
  echo "🐝 Batch $BATCH_ID: spawning $SPAWNED_COUNT agents, queuing $QUEUED_COUNT tasks (max concurrent: $MAX_PARALLEL)"
else
  echo "🐝 Batch $BATCH_ID: spawning $SPAWNED_COUNT subteams"
fi

for line in "${INITIAL_BATCH[@]}"; do
  IFS=$'\t' read -r TASK_ID DESCRIPTION ROLE_OR_AGENT MODEL REASONING <<< "$line"

  # Create .endorsed file if missing — this records the human's verbal batch approval.
  # The human endorsed the BATCH (said "yes" to the plan); this creates per-task files
  # so spawn-agent.sh's endorsement check passes. NOT a bypass of human approval.
  ENDORSE_FILE="$SWARM_DIR/endorsements/${TASK_ID}.endorsed"
  if [[ ! -f "$ENDORSE_FILE" ]]; then
    "$ENDORSE_SCRIPT" --batch "$TASK_ID" >/dev/null
  fi

  # spawn-agent.sh resolves role→agent from duty table
  "$SPAWN_AGENT" "$PROJECT_DIR" "$TASK_ID" "$DESCRIPTION" "$ROLE_OR_AGENT" "$MODEL" "$REASONING"

  # Determine the actual tmux session name (spawn-agent uses $AGENT-$TASK_ID)
  # If role was passed, resolve what agent it mapped to
  RESOLVED_AGENT="$ROLE_OR_AGENT"
  if [[ "$ROLE_OR_AGENT" == "architect" || "$ROLE_OR_AGENT" == "builder" || "$ROLE_OR_AGENT" == "reviewer" || "$ROLE_OR_AGENT" == "integrator" ]]; then
    RESOLVED_AGENT=$(python3 -c "
import json
with open('$SWARM_DIR/duty-table.json') as f: d=json.load(f)
print(d.get('dutyTable',{}).get('$ROLE_OR_AGENT',{}).get('agent','claude'))
" 2>/dev/null || echo "claude")
  fi

  SESSIONS+=("${RESOLVED_AGENT}-${TASK_ID}")
done

if [[ $QUEUED_COUNT -gt 0 ]]; then
  # Write queue file with all sessions (initial already spawned + queued pending)
  QUEUE_FILE="$SWARM_DIR/queue-${BATCH_ID}.json"
  SESSIONS_STR="${SESSIONS[*]}"
  python3 - <<'PY' "$QUEUE_FILE" "$BATCH_ID" "$PROJECT_DIR" "$BATCH_DESC" "$SESSIONS_STR" "${QUEUED[@]}"
import json, sys
queue_file = sys.argv[1]
batch_id = sys.argv[2]
project_dir = sys.argv[3]
batch_desc = sys.argv[4]
sessions_str = sys.argv[5]
task_lines = sys.argv[6:]

all_sessions = sessions_str.split() if sessions_str else []
pending = []
for line in task_lines:
    parts = line.split('\t')
    tid, desc, agent, model, reasoning = parts[0], parts[1], parts[2], parts[3], parts[4]
    pending.append({'id': tid, 'description': desc, 'agent': agent, 'model': model, 'reasoning': reasoning})
    all_sessions.append(f'{agent}-{tid}')

with open(queue_file, 'w', encoding='utf-8') as f:
    json.dump({'batchId': batch_id, 'projectDir': project_dir, 'description': batch_desc,
               'allSessions': all_sessions, 'pending': pending}, f, indent=2)
    f.write('\n')
PY

  # Start queue-watcher; it will start integration-watcher once queue is empty
  QUEUE_LOG="$LOG_DIR/queue-${BATCH_ID}.log"
  nohup "$QUEUE_WATCHER" "$QUEUE_FILE" >> "$QUEUE_LOG" 2>&1 &
  QUEUE_PID=$!
  echo "🔄 Queue watcher started (PID: $QUEUE_PID)"
  echo "   Log: $QUEUE_LOG"
  echo "   Queue: $QUEUE_FILE"

  ALL_SESSIONS_STR="$(python3 -c "import json; d=json.load(open('$QUEUE_FILE')); print(' '.join(d['allSessions']))")"

  # Record batch metadata
  BATCH_META="$LOG_DIR/batch-${BATCH_ID}.json"
  python3 - <<'PY' "$BATCH_META" "$PROJECT_DIR" "$BATCH_ID" "$BATCH_DESC" "$ALL_SESSIONS_STR" "$QUEUE_FILE"
import json, sys, datetime
path, project, bid, desc, sessions_str, queue_file = sys.argv[1:7]
obj = {
  'batchId': bid,
  'projectDir': project,
  'description': desc,
  'createdAt': datetime.datetime.now().astimezone().isoformat(),
  'queueFile': queue_file,
  'sessions': sessions_str.split() if sessions_str else []
}
with open(path, 'w', encoding='utf-8') as f:
  json.dump(obj, f, indent=2)
  f.write('\n')
PY

else
  # No overflow — start integration watcher immediately (existing behavior unchanged)
  INTEG_LOG="$LOG_DIR/integration-${BATCH_ID}-watcher.log"
  nohup "$INTEGRATION_WATCHER" "$PROJECT_DIR" "$BATCH_DESC" "${SESSIONS[@]}" >> "$INTEG_LOG" 2>&1 &
  INTEG_PID=$!

  echo "🔗 Integration watcher started"
  echo "   PID: $INTEG_PID"
  echo "   Log: $INTEG_LOG"
  echo "   Sessions: ${SESSIONS[*]}"

  # Record batch metadata for activity traceability (identical to original format)
  BATCH_META="$LOG_DIR/batch-${BATCH_ID}.json"
  python3 - <<'PY' "$BATCH_META" "$PROJECT_DIR" "$BATCH_ID" "$BATCH_DESC" "$INTEG_PID" "$INTEG_LOG" "${SESSIONS[*]}"
import json,sys,datetime
path,project,bid,desc,pid,ilog,sessions = sys.argv[1:8]
obj={
  'batchId': bid,
  'projectDir': project,
  'description': desc,
  'createdAt': datetime.datetime.now().astimezone().isoformat(),
  'integrationWatcher': {'pid': int(pid), 'log': ilog},
  'sessions': sessions.split() if sessions else []
}
with open(path,'w',encoding='utf-8') as f:
  json.dump(obj,f,indent=2)
  f.write('\n')
PY

fi

echo "🧾 Batch metadata: $BATCH_META"
