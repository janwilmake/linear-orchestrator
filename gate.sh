#!/bin/bash
# One gate for the whole tick. Prints exactly "NO" when there is nothing for the
# model to do, otherwise prints a compact context block.
#
# Why a state hash: 94 consecutive ticks one night printed the same numbers and
# changed nothing. The model only needs to wake when the *world* changed, not
# when the clock did.
#
# Linear is included cheaply: only when slots > 0 (a new ticket the machine
# cannot start is not worth waking for), through the agent-codemode CLI, which
# inherits Claude Code's Linear OAuth from the Keychain — no token, no model.
# The eligible-ticket ids fold into the state hash, so a new Urgent is seen on
# the next 5-minute gate, not only on the 30-minute queue rebuild.

# --- config: put your values in .env next to this file (gitignored; see .env.example) ---
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SELF/.env" ] && set -a && . "$SELF/.env" && set +a
REPO="${LO_REPO:-/path/to/your/repo}"
BASE="${LO_BASE:-dev}"
TEAM="${LO_TEAM:-Your Team}"        # Linear team name
PREFIX="${LO_PREFIX:-XXX}"          # ticket id prefix, e.g. HYR2
TIER1="${LO_TIER1:-}"               # preferred assignee DISPLAY name (unassigned always eligible)
TIER2="${LO_TIER2:-}"               # fallback assignee display name
RAM_PER_AGENT="${LO_RAM_PER_AGENT:-2.5}"

STATE=~/.claude/linear-orchestrator/gate-state
QUEUE=~/.claude/linear-orchestrator/${PREFIX}-queue.json
AC="${AGENT_CODEMODE:-$(command -v agent-codemode 2>/dev/null || echo "$HOME/.local/node/bin/agent-codemode")}"

# --- hourly base-branch refresh (refuses, never forces) ---
stamp=~/.claude/linear-orchestrator/last-fetch
notes=""
if [ ! -f "$stamp" ] || [ $(( $(date +%s) - $(stat -f %m "$stamp") )) -gt 3600 ]; then
  if [ -z "$(git -C $REPO status --porcelain --untracked-files=no)" ] \
     && [ "$(git -C $REPO branch --show-current)" = "$BASE" ]; then
    before=$(git -C $REPO rev-parse --short HEAD)
    git -C $REPO pull --ff-only --quiet origin $BASE 2>/dev/null
    after=$(git -C $REPO rev-parse --short HEAD)
    [ "$before" != "$after" ] && notes="dev $before -> $after"
    touch "$stamp"
  else
    notes="dev NOT refreshed: repo is dirty or not on $BASE"
  fi
fi

# --- reap leaked dev servers from dead slots ---
for n in 1 2 3 4 5 6 7 8; do
  p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
  if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
    pids=$(pgrep -f "/.claude/agents/agent-$n/" 2>/dev/null)
    if [ -n "$pids" ]; then
      notes="$notes${notes:+; }reaped agent-$n"
      kill $pids 2>/dev/null
    fi
  fi
done
sleep 2

# --- capacity ---
cores=$(sysctl -n hw.ncpu)
ramgb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
load=$(sysctl -n vm.loadavg | awk '{print $2}')
freegb=$(vm_stat | awk '/page size of/{ps=$8} /Pages free/{f=$3}
  /Pages speculative/{s=$3} /Pages purgeable/{p=$3} /Pages inactive/{i=$3}
  END{gsub("\\.","",f); gsub("\\.","",s); gsub("\\.","",p); gsub("\\.","",i)
      printf "%.1f", (f+s+p+i)*ps/1073741824}')
diskgb=$(df -g / | tail -1 | awk '{print $4}')
busy=0
for n in 1 2 3 4 5 6 7 8; do
  p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && busy=$((busy+1))
done

max_agents=$(awk -v r=$ramgb -v a=$RAM_PER_AGENT 'BEGIN{m=int(r/a); print (m>4?4:m)}')
slots=$(awk -v m=$max_agents -v b=$busy -v f=$freegb -v a=$RAM_PER_AGENT -v l=$load \
            -v c=$cores -v d=$diskgb 'BEGIN{
  if (l > c*0.7 || d < 10) { print 0; exit }
  byram = int(f/a); bycap = m-b; s = (byram<bycap?byram:bycap)
  print (s<0?0:s) }')

# --- the world, in one gh call ---
prs=$(gh pr list --state open --base $BASE --limit 60 \
  --json number,isDraft,mergeable,body,labels,statusCheckRollup 2>/dev/null)
[ -z "$prs" ] && { echo "GATE-ERROR: gh pr list failed"; exit 0; }

verdicts=$(printf '%s' "$prs" | jq -c '[ .[] | {
    pr: .number, draft: .isDraft, merge: .mergeable,
    mine: ((.body // "") | test("🌙")),
    invalid: ([.labels[]?.name] | index("invalid") != null),
    ci: ( [ .statusCheckRollup[]? | select(.conclusion != null
              and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL") ] as $c
          | if   ([ $c[] | select((.name // "") | startswith("Test (shard")) ] | length) == 0 then "not-run"
            elif ([ $c[] | select(.conclusion != "SUCCESS") ] | length) > 0 then "failing"
            else "green" end ) } ] | sort_by(.pr)')

regate=$(printf '%s' "$verdicts" | jq -c '[ .[] | select(.draft==false and .mine)
          | select(.merge=="CONFLICTING" or .ci=="failing") ]')
invalid=$(printf '%s' "$verdicts" | jq -c '[ .[] | select(.invalid and .mine) | .pr ]')
drafts=$(printf '%s' "$verdicts" | jq -c '[ .[] | select(.draft) | .pr ]')

n_regate=$(printf '%s' "$regate"  | jq 'length')
n_invalid=$(printf '%s' "$invalid" | jq 'length')
n_drafts=$(printf '%s' "$drafts"  | jq 'length')

# --- Linear ready column, but only when a slot could take it ---
# Cheap pre-filter (assignee tier + not archived); the model still applies the
# judgment drop-rules and dedups against open PRs. New candidate -> hash change.
todo_ids=""
if [ "$slots" -gt 0 ]; then
  if [ -x "$AC" ] || command -v "$AC" >/dev/null 2>&1; then
    tj=$("$AC" call linear list_issues \
      --json "{\"team\":\"$TEAM\",\"state\":\"Todo\",\"includeArchived\":false,\"fields\":[\"assignee\",\"archivedAt\",\"status\"]}" \
      --text 2>/dev/null)
    if [ -n "$tj" ]; then
      todo_ids=$(printf '%s' "$tj" | jq -r --arg t1 "$TIER1" --arg t2 "$TIER2" '
        [ .issues[]?
          | select(.archivedAt == null)
          | select(.assignee == null or .assignee == "" or .assignee == $t1 or .assignee == $t2)
          | .id ] | sort | join(",")' 2>/dev/null)
    else
      notes="$notes${notes:+; }linear query failed (token expired? claude mcp login linear)"
    fi
  else
    notes="$notes${notes:+; }agent-codemode CLI not found; Linear check skipped"
  fi
fi

# queue staleness only matters when there is somewhere to put an agent
queue_stale=no
if [ "$slots" -gt 0 ]; then
  if [ ! -f "$QUEUE" ]; then queue_stale=yes
  else
    built=$(jq -r '.builtAt // ""' "$QUEUE" 2>/dev/null)
    age=$(( $(date +%s) - $(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${built%.*}Z" +%s 2>/dev/null || echo 0) ))
    [ "$age" -gt 1800 ] && queue_stale=yes
  fi
fi

# --- did anything change since last tick? (PR verdicts + eligible ticket ids) ---
hash=$(printf '%s|%s' "$verdicts" "$todo_ids" | shasum | cut -c1-16)
prev=$(cat "$STATE" 2>/dev/null)
printf '%s' "$hash" > "$STATE"

# --- decide ---
work=no
[ "$n_regate"  -gt 0 ] && work=yes            # acted on even at slots 0
[ "$n_invalid" -gt 0 ] && work=yes
[ "$slots" -gt 0 ] && [ "$n_drafts" -gt 0 ] && work=yes
[ "$slots" -gt 0 ] && [ "$queue_stale" = yes ] && work=yes
[ "$slots" -gt 0 ] && [ -n "$todo_ids" ] && [ "$hash" != "$prev" ] && work=yes
[ -n "$notes" ] && work=yes                   # a reap or a refused fetch is worth a line

if [ "$work" = no ] && [ "$hash" = "$prev" ]; then
  echo "NO"
  exit 0
fi

# --- otherwise: everything the model needs, nothing it does not ---
echo "load1=$load freegb=$freegb diskgb=$diskgb busy=$busy slots=$slots"
[ -n "$notes" ]           && echo "notes: $notes"
[ "$hash" != "$prev" ]    && echo "world-changed: yes"
[ "$n_regate"  -gt 0 ]    && echo "REGATE: $regate"
[ "$n_invalid" -gt 0 ]    && echo "INVALID: $invalid"
[ "$n_drafts"  -gt 0 ]    && echo "DRAFTS: $drafts"
[ "$slots" -gt 0 ] && [ -n "$todo_ids" ] && echo "TODO-CANDIDATES: $todo_ids"
[ "$queue_stale" = yes ]  && echo "queue: stale, rebuild before 2d"
exit 0
