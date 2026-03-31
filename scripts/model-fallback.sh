#!/usr/bin/env bash
# model-fallback.sh — Pick the next available model for a role after a failure
#
# Usage: model-fallback.sh <role> <failed-agent> <failed-model>
# Output: agent|model|nonInteractiveCmd   (pipe-separated)
# Exit 0 = found fallback, Exit 1 = no fallback available
#
# Fallback priority per role:
#   architect:  claude-opus → claude-sonnet → gemini-2.5-flash
#   builder:    codex → claude-sonnet → gemini-2.5-flash → claude-opus
#   reviewer:   gemini-2.5-flash → claude-sonnet → claude-opus
#   integrator: claude-opus → claude-sonnet → gemini-2.5-flash

set -euo pipefail

ROLE="${1:?Usage: model-fallback.sh <role> <failed-agent> <failed-model>}"
FAILED_AGENT="${2:?Missing failed-agent}"
FAILED_MODEL="${3:?Missing failed-model}"

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"

# All candidate models in priority order per role
# Each entry: agent:model
declare -A FALLBACK_CHAINS
FALLBACK_CHAINS[architect]="claude:claude-opus-4-6 claude:claude-sonnet-4-6 gemini:gemini-2.5-flash codex:gpt-5.3-codex"
FALLBACK_CHAINS[builder]="codex:gpt-5.3-codex claude:claude-sonnet-4-6 gemini:gemini-2.5-flash claude:claude-opus-4-6"
FALLBACK_CHAINS[reviewer]="gemini:gemini-2.5-flash gemini:gemini-2.5-pro claude:claude-sonnet-4-6 claude:claude-opus-4-6"
FALLBACK_CHAINS[integrator]="claude:claude-opus-4-6 claude:claude-sonnet-4-6 gemini:gemini-2.5-flash codex:gpt-5.3-codex"

CHAIN="${FALLBACK_CHAINS[$ROLE]:-${FALLBACK_CHAINS[builder]}}"

build_cmd() {
  local agent="$1" model="$2"
  case "$agent" in
    claude) echo "claude --model $model --permission-mode bypassPermissions --print" ;;
    codex)  echo "codex --model $model --full-auto exec" ;;
    gemini) echo "gemini -m $model -p" ;;
  esac
}

echo "[model-fallback] Role=$ROLE, failed=$FAILED_AGENT/$FAILED_MODEL" >&2
echo "[model-fallback] Testing fallback chain..." >&2

for candidate in $CHAIN; do
  IFS=':' read -r agent model <<< "$candidate"

  # Skip the one that just failed
  if [[ "$agent" == "$FAILED_AGENT" && "$model" == "$FAILED_MODEL" ]]; then
    echo "[model-fallback]   skip $agent/$model (just failed)" >&2
    continue
  fi

  # Quick health check (15s timeout — faster than full assess)
  echo "[model-fallback]   testing $agent/$model ..." >&2
  if "$SWARM_DIR/try-model.sh" "$agent" "$model" 2>/dev/null; then
    CMD=$(build_cmd "$agent" "$model")
    echo "[model-fallback] ✅ Fallback found: $agent/$model" >&2
    echo "${agent}|${model}|${CMD}"
    exit 0
  else
    echo "[model-fallback]   ❌ $agent/$model also unavailable" >&2
  fi
done

echo "[model-fallback] ❌ No fallback available for $ROLE" >&2
exit 1
