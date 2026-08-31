#!/bin/bash
# One gate for the whole tick. Prints a "NO" line with its reason when there is
# nothing for the model to do, otherwise prints a compact context block.
#
# Two modes:
#   gate.sh            one probe, print, exit — for a fixed-interval loop.
#   gate.sh --peek     the same probe, but never writes the state file — for a
#                      heartbeat tick that only wants to LOOK while a --wait
#                      waiter is alive. A plain run rewrites the hash the waiter
#                      compares against, so the waiter's next probe sees no
#                      change and the "world-changed: yes" it owed the model is
#                      swallowed. Use --peek whenever a waiter is running.
#   gate.sh --wait [s] block until there IS work, then print and exit — for an
#                      event-driven loop. Run it with run_in_background: the
#                      exit is what wakes the model, so a quiet night costs no
#                      turns at all instead of one every 5 minutes.
#
# Why a state hash: 94 consecutive ticks one night printed the same numbers and
# changed nothing. The model only needs to wake when the *world* changed, not
# when the clock did.
#
# Linear is included cheaply: only when slots > 0 (a new ticket the machine
# cannot start is not worth waking for), through the agent-codemode CLI, which
# inherits Claude Code's Linear OAuth from the Keychain — no token, no model.
# The eligible-ticket ids fold into the state hash, so a new Urgent is seen on
# the next gate, not only on the 30-minute queue rebuild.

# --- config: put your values in .env next to this file (gitignored; see .env.example) ---
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SELF/.env" ] && set -a && . "$SELF/.env" && set +a
REPO="${LO_REPO:-/path/to/your/repo}"
BASE="${LO_BASE:-dev}"
TEAM="${LO_TEAM:-Your Team}"        # Linear team name
PREFIX="${LO_PREFIX:-XXX}"          # ticket id prefix, e.g. HYR2
TIER1="${LO_TIER1:-}"               # preferred assignee DISPLAY name
TIER2="${LO_TIER2:-}"               # fallback assignee display name
# Two opt-in widenings, both OFF by default. Unassigned and Backlog are work
# nobody handed to this loop: somebody who moves a ticket to Todo and puts a
# name on it has decided it is ready, and that decision is the whole signal.
# Taking either without being asked is how an orchestrator starts work its owner
# never queued — so each is a deliberate switch, not a default.
ALLOW_UNASSIGNED="${LO_ALLOW_UNASSIGNED:-0}"  # 1 = unassigned tickets count too
ALLOW_BACKLOG="${LO_ALLOW_BACKLOG:-0}"        # 1 = fall to Backlog when Todo is empty
# Which PRs are THIS loop's. Every linear-orchestrator writes the same bare 🌙
# marker, so on a repo with two of them running the marker cannot tell them
# apart: each reads the other's PRs as its own and reviews, re-drafts and
# answers feedback on them. LO_OWNER puts a per-instance tag in the marker and
# the gate matches on that. Empty keeps the bare marker — correct only when a
# single orchestrator touches the repo.
OWNER="${LO_OWNER:-}"
PR_MARKER="🌙${OWNER:+ lo:$OWNER}"
RAM_PER_AGENT="${LO_RAM_PER_AGENT:-2.5}"
# Ceiling on concurrent agents. 0 = unlimited, and unlimited is the default: the
# tick spawns every slot free RAM allows, so the loop reaches full capacity on
# the first tick with work instead of climbing one agent at a time.
MAX_AGENTS_CAP="${LO_MAX_AGENTS:-0}"
# How many agent slots to probe for liveness. This must cover the most agents
# that can run at once or a busy agent above the scan reads as a free slot and
# the loop double-spawns onto it. Defaults to what total RAM allows, floor 8.
SLOT_SCAN="${LO_SLOT_SCAN:-$(awk -v r="$(( $(sysctl -n hw.memsize) / 1073741824 ))" \
  -v a="${LO_RAM_PER_AGENT:-2.5}" 'BEGIN{m=int(r/a); print (m<8?8:m)}')}"
WAIT_INTERVAL="${LO_WAIT_INTERVAL:-60}"   # --wait: seconds between probes
WAIT_MAX="${LO_WAIT_MAX:-2400}"           # --wait: give up and let the model re-arm
# Comments written before the loop started marking its own carry no marker, so
# they would all read as human. This floor is the day marking began: nothing
# before it is ever treated as feedback.
FEEDBACK_SINCE="${LO_FEEDBACK_SINCE:-2026-08-18T17:00:00Z}"
# Whose comments count as feedback. Comma-separated GitHub logins, case
# insensitive. Empty means every non-bot login counts.
FEEDBACK_LOGINS="${LO_FEEDBACK_LOGINS:-}"

# One Linear read, filtered to the tickets this instance is allowed to take.
# $1 is the status TYPE, not the column name — `state:"Backlog"` also returns
# every other backlog-type status (Planned, Ideas, To Discuss on some
# workspaces), so this is a cheap shortlist and the model still filters to the
# exact column before it spawns anything.
#
# Assignee is the separation between two orchestrators on one tracker: each
# takes only its own tiers, so neither can claim the other's tickets. That is
# why an empty tier is dropped rather than matched — an unset LO_TIER2 would
# otherwise equal the empty assignee string and quietly re-admit every
# unassigned ticket that ALLOW_UNASSIGNED is meant to gate.
LINEAR_ERR=""
linear_ids() {
  local tj
  tj=$("$AC" call linear list_issues \
    --json "{\"team\":\"$TEAM\",\"state\":\"$1\",\"includeArchived\":false,\"fields\":[\"assignee\",\"archivedAt\",\"status\"]}" \
    --text 2>/dev/null)
  if [ -z "$tj" ]; then
    LINEAR_ERR="linear query failed (token expired? claude mcp login linear)"
    return 0
  fi
  printf '%s' "$tj" | jq -r --arg t1 "$TIER1" --arg t2 "$TIER2" \
    --argjson unassigned "$([ "$ALLOW_UNASSIGNED" = 1 ] && echo true || echo false)" '
    ([$t1, $t2] | map(select(. != null and . != ""))) as $tiers
    | [ .issues[]?
        | select(.archivedAt == null)
        | (.assignee // "") as $a
        | select( ($unassigned and $a == "") or ($tiers | index($a) != null) )
        | .id ] | sort | join(",")' 2>/dev/null
}

STATE=~/.claude/linear-orchestrator/gate-state
QUEUE=~/.claude/linear-orchestrator/${PREFIX}-queue.json
AC="${AGENT_CODEMODE:-$(command -v agent-codemode 2>/dev/null || echo "$HOME/.local/node/bin/agent-codemode")}"

MODE=once
PEEK=0
[ "$1" = "--peek" ] && PEEK=1

# Every state write goes through here. --peek makes it a no-op, so a look never
# moves the world forward for the waiter that is watching it.
save_state() { [ "$PEEK" = 1 ] || printf '%s' "$1" > "$STATE"; }
NOREASON=""

# probe: measure the world once. Prints the context block and returns 0 when
# there is work; prints nothing and returns 1 when there is not, leaving the
# reason in $NOREASON for the caller to print or swallow.
probe() {
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
  for n in $(seq 1 "$SLOT_SCAN"); do
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
  # A live agent's branch is not work: it is work in progress. Collect the
  # branches here so the PR lists below can drop them, or the waiter exits the
  # instant an agent drafts its own PR and every re-arm spins on the same PR.
  busy=0
  live_branches=""
  for n in $(seq 1 "$SLOT_SCAN"); do
    p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      busy=$((busy+1))
      b=$(git -C ~/.claude/agents/agent-$n branch --show-current 2>/dev/null)
      [ -n "$b" ] && live_branches="$live_branches$b
"
    fi
  done
  held=$(printf '%s' "$live_branches" | jq -Rsc 'split("\n") | map(select(length>0))')

  # --- PRs already in an agent's hands ---
  # The branch test above cannot see an agent that has not run `gh pr checkout`
  # yet, and "yet" can be half an hour: an agent sent to answer a question reads
  # the code long before it touches the branch. Guessing a grace period was
  # wrong twice, so the marker names the exact fact instead — a dispatch writes
  # the agent's SLOT into a file named after the PR, and the PR is in hand for
  # precisely as long as that slot's lock is alive. An agent that dies frees its
  # PR on the next probe; one that finishes frees it the moment its lock goes.
  # The 10-minute floor covers only the seconds between the spawn and the marker.
  dispatch_dir="$HOME/.claude/linear-orchestrator/dispatched"
  mkdir -p "$dispatch_dir"
  now_s=$(date +%s)
  inhand=""
  for f in "$dispatch_dir"/*; do
    [ -f "$f" ] || continue
    slot=$(cat "$f" 2>/dev/null)
    lp=$(cat ~/.claude/agents/agent-$slot.lock 2>/dev/null)
    if { [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; } \
       || [ $(( now_s - $(stat -f %m "$f") )) -lt 600 ]; then
      inhand="$inhand$(basename "$f")
"
    else
      rm -f "$f"
    fi
  done
  inhand=$(printf '%s' "$inhand" | jq -Rsc '[ split("\n")[] | select(length>0) | tonumber ]')

  # c=0 is "no ceiling": total RAM is then the only bound on how many can run.
  max_agents=$(awk -v r=$ramgb -v a=$RAM_PER_AGENT -v c=$MAX_AGENTS_CAP 'BEGIN{m=int(r/a); print (c>0 && m>c?c:m)}')
  # What the ceiling is doing, in words, for the lines that report capacity.
  if [ "$MAX_AGENTS_CAP" -gt 0 ] 2>/dev/null; then capnote=" (LO_MAX_AGENTS=$MAX_AGENTS_CAP)"; else capnote=" (uncapped)"; fi
  slots=$(awk -v m=$max_agents -v b=$busy -v f=$freegb -v a=$RAM_PER_AGENT -v l=$load \
              -v c=$cores -v d=$diskgb 'BEGIN{
    if (l > c*0.7 || d < 10) { print 0; exit }
    byram = int(f/a); bycap = m-b; s = (byram<bycap?byram:bycap)
    print (s<0?0:s) }')

  # Every `gh` call below names the repo. Without --repo, gh reads the CALLER's
  # working directory, so a gate run from anywhere but the checkout silently
  # reports on a different repo — and reports it as an empty, healthy board.
  slug=$(git -C "$REPO" remote get-url origin 2>/dev/null \
         | sed -e 's#.*github.com[:/]##' -e 's#\.git$##')

  # --- the world, in one gh call ---
  # NOT filtered by --base: a stacked layer's base is the layer below it, never
  # $BASE, so filtering here made every layer above the first invisible to the
  # gate — it would sit open and unreviewed until a human found it by hand.
  # `.mine` below is what keeps this to the loop's own PRs, and `main` is
  # excluded so a release PR is never mistaken for work.
  prs=$(gh pr list --repo "$slug" --state open --limit 100 \
    --json number,isDraft,mergeable,body,labels,statusCheckRollup,headRefName,baseRefName 2>/dev/null)
  # A broken gh is itself worth waking for — never wait quietly on it.
  [ -z "$prs" ] && { echo "GATE-ERROR: gh pr list failed"; return 0; }

  verdicts=$(printf '%s' "$prs" | jq -c --arg m "$PR_MARKER" '[ .[] | {
      pr: .number, draft: .isDraft, merge: .mergeable, head: .headRefName,
      base: .baseRefName,
      mine: ((.body // "") | contains($m)),
      invalid: ([.labels[]?.name] | index("invalid") != null),
      # Only a real verdict counts. Three things look like one and are not:
      #   ""         a run still QUEUED or IN_PROGRESS. GitHub returns an empty
      #              string here, NOT null, so a `!= null` guard lets it through
      #              and every in-flight check reads as a failure.
      #   CANCELLED  a run superseded by a newer push. A force-push cancels the
      #              runs in flight and starts fresh ones, and the rollup returns
      #              BOTH for the same check name. Cancelled is "no verdict yet",
      #              never "failed" — treating it as failure re-drafts a healthy PR.
      #   SKIPPED / NEUTRAL — never ran, or ran and declined to judge.
      # Both of the first two were found on 26 Aug, when a restack force-pushed
      # five promoted PRs and the gate reported them as failing CI.
      ci: ( [ .statusCheckRollup[]? | select(.conclusion != null and .conclusion != ""
                and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL"
                and .conclusion != "CANCELLED") ] as $c
            | if   ([ $c[] | select((.name // "") | startswith("Test (shard")) ] | length) == 0 then "not-run"
              elif ([ $c[] | select(.conclusion != "SUCCESS") ] | length) > 0 then "failing"
              else "green" end ) } ] | map(select(.base != "main")) | sort_by(.pr)')

  regate=$(printf '%s' "$verdicts" | jq -c --argjson held "$held" --argjson inhand "$inhand" '[ .[]
            | select(.draft==false and .mine)
            | select(.merge=="CONFLICTING" or .ci=="failing")
            | .pr as $p | select($inhand | index($p) | not)
            | .head as $h | select($held | index($h) | not) ]')
  # invalid is deliberately NOT filtered by $held: the label is the only durable
  # record that a reclaim is owed, and steps 2a.1-4 need no slot.
  invalid=$(printf '%s' "$verdicts" | jq -c '[ .[] | select(.invalid and .mine) | .pr ]')
  # .mine matters as much as $held here: a human's draft PR is not the loop's to
  # push commits to.
  drafts=$(printf '%s' "$verdicts" | jq -c --argjson held "$held" --argjson inhand "$inhand" '[ .[]
            | select(.draft and .mine)
            | .pr as $p | select($inhand | index($p) | not)
            | .head as $h | select($held | index($h) | not) | .pr ]')

  # A layer whose base is another branch is part of a stack. It appears in DRAFTS
  # like any other draft, but the model cannot review a stack in an arbitrary
  # order — layer 2 is unreadable before layer 1 — so name the base here and let
  # it sort them bottom-up.
  stack=$(printf '%s' "$verdicts" | jq -c --arg b "$BASE" '[ .[]
            | select(.mine and .base != $b)
            | {pr, base, draft, head} ]')

  # A layer goes stale the moment its base layer takes a commit — and NOTHING
  # else here notices. `mergeable` compares the layer against its base and stays
  # MERGEABLE, because being behind is not a conflict. So a fix pass on layer 1
  # silently leaves layers 2..6 built on a head that no longer exists, and the
  # forge refuses to merge the stack while every gate here still reads green.
  # Seen on the HYR2-993 stack: one fix commit on layer 1 put four layers behind.
  #
  # `behind_by` from the compare API is the only signal that says so. One call
  # per layer, and only when a stack exists at all — which is almost never, so
  # the common probe pays nothing. Failures leave the layer out rather than
  # inventing a zero: a restack claimed on a failed lookup is worse than silence.
  restack="[]"
  if [ "$(printf '%s' "$stack" | jq 'length')" -gt 0 ]; then
    restack=$(printf '%s' "$stack" | jq -c '.[] | [.pr, .base, .head] | @tsv' -r | while IFS=$'\t' read -r p b h; do
      cmp=$(gh api "repos/$slug/compare/$b...$h" --jq '.behind_by' 2>/dev/null)
      # A non-numeric answer is a failed lookup, and [ -gt ] returns false for it
      # rather than treating it as a number. `case` cannot be used here: bash
      # mis-parses a case pattern's `)` inside a command substitution.
      if [ -n "$cmp" ] && [ "$cmp" -gt 0 ] 2>/dev/null; then
        printf '{"pr":%s,"base":"%s","behind":%s}\n' "$p" "$b" "$cmp"
      fi
    done | jq -s -c '.')
  fi

  # --- human feedback: comments on the loop's PRs that nobody answered ---
  # The agents post through the user's own `gh`, so every comment carries the
  # user's login and the author field can never separate a person from a machine.
  # So the loop marks its OWN instead — every comment it writes contains "🌙" —
  # and an unmarked comment on one of its PRs is a person talking to it.
  #
  # "Already answered" is not a local flag either: the reply carries
  # "ack:<comment-id>", so the record lives on GitHub and survives a deleted
  # cache, a /clear, a restart and a compaction. The id in the ack is what makes
  # it safe — without it, an agent posting its own fix-pass comment would mask a
  # question the user asked while that agent was working.
  #
  # The scan is repo-wide (PRs are issues, so one endpoint covers both), which is
  # what catches a comment on an already-merged PR. It IS limited to PRs the loop
  # opened, because ordinary review chatter between two people on their own PR is
  # not an instruction to a machine.
  #
  # FEEDBACK_LOGINS narrows it further: only those logins steer the loop. Set it
  # when the repo has people who comment but must not dispatch work. Leave it
  # empty and every non-bot login counts.
  since="$FEEDBACK_SINCE"
  win=$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)
  # ISO-8601 sorts lexically, so the later of the two is just the bigger string.
  [ "$win" \> "$since" ] && since="$win"
  cmts=$(gh api "repos/$slug/issues/comments?since=$since&sort=created&direction=desc&per_page=100" \
    --jq '[ .[] | select((.user.type // "") != "Bot")
            | { id, body, who: .user.login, pr: (.issue_url | sub(".*/"; "")) } ]' 2>/dev/null)
  [ -z "$cmts" ] && cmts='[]'
  acked=$(printf '%s' "$cmts" | jq -c '[ .[] | select(.body | test("🌙"))
            | .body | [ scan("ack:([0-9]+)") ] ] | flatten | map(tonumber)')
  pending=$(printf '%s' "$cmts" | jq -c --argjson acked "$acked" --arg allow "$FEEDBACK_LOGINS" '
            ($allow | ascii_downcase | split(",") | map(sub("^ +";"") | sub(" +$";""))
              | map(select(length > 0))) as $who
            | [ .[]
            | select((.body | test("🌙")) | not)
            | select(($who | length) == 0 or ((.who | ascii_downcase) as $w | $who | index($w) != null))
            | .id as $i | select($acked | index($i) | not) ]')

  # SUBMITTED REVIEWS are a second human surface the comments endpoint never
  # returns: a review submitted from the Files-changed tab is not an issue
  # comment, so a reviewer can write twenty of them and the loop sees nothing.
  # Seen on a real run (2026-08-31): 29 reviews in one morning, zero surfaced.
  # There is no repo-wide reviews endpoint, so one GraphQL query sweeps the 100
  # most recently updated open+merged PRs and their last 10 reviews each.
  # A review by the loop cannot exist — agents post plain comments by rule — so
  # the 🌙 test is only a guard. Acks reuse the same ack:<id> comment mechanism
  # (review ids and comment ids are both numeric and never collide in practice).
  # FEEDBACK entries from here carry kind:"review": the tick reads the body via
  # `gh api repos/<slug>/pulls/<pr>/reviews/<id>`, not the comments endpoint.
  rowner=${slug%%/*}; rname=${slug##*/}
  rpending=$(gh api graphql \
    -f owner="$rowner" -f name="$rname" \
    -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(states:[OPEN,MERGED],first:100,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number reviews(last:10){nodes{databaseId submittedAt bodyText author{login __typename}}}}}}}' \
    --jq '.data.repository.pullRequests.nodes' 2>/dev/null)
  [ -z "$rpending" ] && rpending='[]'
  rpending=$(printf '%s' "$rpending" | jq -c --argjson acked "$acked" \
      --arg allow "$FEEDBACK_LOGINS" --arg since "$since" '
      ($allow | ascii_downcase | split(",") | map(sub("^ +";"") | sub(" +$";""))
        | map(select(length > 0))) as $who
      | [ .[] | .number as $n | .reviews.nodes[]?
      | select((.bodyText // "") != "")
      | select(.author != null and .author.__typename != "Bot")
      | select(.submittedAt >= $since)
      | select((.bodyText | test("🌙")) | not)
      | select(($who | length) == 0 or ((.author.login | ascii_downcase) as $w | $who | index($w) != null))
      | .databaseId as $i | select($acked | index($i) | not)
      | { id: $i, who: .author.login, pr: ($n|tostring), kind: "review" } ]' 2>/dev/null)
  [ -z "$rpending" ] && rpending='[]'
  pending=$(jq -c -n --argjson a "$pending" --argjson b "$rpending" '$a + $b')

  # The acked-scan above reads ONE page of the newest repo-wide comments. On a
  # busy day the loop writes hundreds, so an ack posted hours ago rolls off the
  # page and its review resurfaces as unanswered — seen flapping on a real run
  # (2026-08-31). Pending is tiny, so verify each candidate against ITS OWN
  # PR's comments, where the ack lives and cannot be crowded out.
  if [ "$(printf '%s' "$pending" | jq 'length')" -gt 0 ]; then
    verified='[]'
    for row in $(printf '%s' "$pending" | jq -c '.[]'); do
      vid=$(printf '%s' "$row" | jq -r '.id')
      vpr=$(printf '%s' "$row" | jq -r '.pr')
      if gh api "repos/$slug/issues/$vpr/comments?per_page=100" \
           --jq '.[].body' 2>/dev/null | grep -q "ack:$vid"; then
        continue
      fi
      verified=$(printf '%s' "$verified" | jq -c --argjson r "$row" '. + [$r]')
    done
    pending="$verified"
  fi

  feedback='[]'
  if [ "$(printf '%s' "$pending" | jq 'length')" -gt 0 ]; then
    # Only now is it worth asking which PRs are the loop's. --state all is what
    # reaches a merged PR; the 🌙 body test is what keeps a human's PR out.
    minepr=$(gh pr list --repo "$slug" --state all --limit 100 --json number,body,state 2>/dev/null \
      | jq -c --arg m "$PR_MARKER" '[ .[] | select((.body // "") | contains($m))
          | { pr: (.number|tostring), state } ]')
    [ -z "$minepr" ] && minepr='[]'
    feedback=$(printf '%s' "$pending" | jq -c --argjson mine "$minepr" '[ .[]
      | .pr as $p | ($mine[] | select(.pr == $p)) as $m
      | { pr: ($p|tonumber), id, who, kind: (.kind // "comment"), state: $m.state } ]')
  fi
  n_feedback=$(printf '%s' "$feedback" | jq 'length')

  n_regate=$(printf '%s' "$regate"  | jq 'length')
  n_invalid=$(printf '%s' "$invalid" | jq 'length')
  n_drafts=$(printf '%s' "$drafts"  | jq 'length')
  n_stack=$(printf '%s' "$stack"   | jq 'length')
  n_restack=$(printf '%s' "$restack" | jq 'length')

  # --- Linear ready column, but only when a slot could take it ---
  # Cheap pre-filter (assignee tier + not archived); the model still applies the
  # judgment drop-rules and dedups against open PRs. New candidate -> hash change.
  todo_ids=""
  todo_source=""
  if [ "$slots" -gt 0 ]; then
    if [ -x "$AC" ] || command -v "$AC" >/dev/null 2>&1; then
      LINEAR_ERR=""
      todo_ids=$(linear_ids Todo)
      [ -n "$todo_ids" ] && todo_source=Todo
      # Backlog is opt-in AND strictly second. A Todo ticket outranks a Backlog
      # one at any priority, because somebody deliberately moved it to Todo — so
      # the fall happens only when Todo yields nothing eligible at all. Reading
      # it here rather than leaving it to the model is what lets the gate WAKE
      # on backlog-only work: the wake conditions below all need a non-empty
      # candidate list, so a backlog pass the gate never saw could not run on an
      # otherwise idle night.
      if [ -z "$todo_ids" ] && [ "$ALLOW_BACKLOG" = 1 ] && [ -z "$LINEAR_ERR" ]; then
        todo_ids=$(linear_ids Backlog)
        [ -n "$todo_ids" ] && todo_source=Backlog
      fi
      [ -n "$LINEAR_ERR" ] && notes="$notes${notes:+; }$LINEAR_ERR"
    else
      notes="$notes${notes:+; }agent-codemode CLI not found; Linear check skipped"
    fi
    # Subtract the ids the model has already judged un-runnable. They live in
    # QUEUE's `skipped` list, written by the last rebuild. Without this a ticket
    # the loop will never take stays in todo_ids forever, and the rule below
    # ("ids present AND the world hash moved") then fires on every commit, CI
    # transition and PR comment that the running agents produce — a wake every
    # couple of minutes with nothing to do. Seen on a real run with HYR2-972.
    if [ -n "$todo_ids" ] && [ -f "$QUEUE" ]; then
      skipped=$(jq -r '[.skipped[]?.id] | join(",")' "$QUEUE" 2>/dev/null)
      if [ -n "$skipped" ]; then
        todo_ids=$(printf '%s' "$todo_ids" | tr ',' '\n' \
          | grep -vxF -f <(printf '%s' "$skipped" | tr ',' '\n') \
          | paste -sd, - )
      fi
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
  hash=$(printf '%s|%s|%s' "$verdicts" "$todo_ids" "$feedback" | shasum | cut -c1-16)
  prev=$(cat "$STATE" 2>/dev/null)

  # --- decide ---
  work=no
  [ "$n_regate"  -gt 0 ] && work=yes            # acted on even at slots 0
  [ "$n_invalid" -gt 0 ] && work=yes
  # Feedback needs no slot to act on: a reply, a re-draft and a follow-up ticket
  # are all free. Only the rework behind it needs an agent.
  [ "$n_feedback" -gt 0 ] && work=yes
  [ "$slots" -gt 0 ] && [ "$n_drafts" -gt 0 ] && work=yes
  # A stale queue is only work when Linear has something to rebuild it FROM.
  # Without this the loop wakes every 30 minutes on an empty ready column, to
  # rebuild an empty file into an identical empty file.
  [ "$slots" -gt 0 ] && [ "$queue_stale" = yes ] && [ -n "$todo_ids" ] && work=yes
  [ "$slots" -gt 0 ] && [ -n "$todo_ids" ] && [ "$hash" != "$prev" ] && work=yes
  # A note is NOT work. A reap frees RAM, which the slot count already shows; an
  # hourly `dev` refresh matters only through what it breaks, which REGATE finds
  # on its own; and a refused refresh would otherwise wake the model every hour
  # for the rest of the night. The note still reaches the user either way — the
  # block prints it below, and the NO line carries it.

  if [ "$work" = no ]; then
    # Say WHY there is nothing to wake for. A bare "NO" hides the difference
    # between "the board is empty" and "the board has work the machine cannot
    # start", and those two want opposite responses from the user.
    # No extra calls: every number below is already measured above.
    if [ "$slots" -eq 0 ]; then
      bycap=$(( max_agents - busy ))
      if awk -v l=$load -v c=$cores 'BEGIN{exit !(l > c*0.7)}'; then
        why="load $load over $(awk -v c=$cores 'BEGIN{printf "%.1f", c*0.7}')"
      elif [ "$diskgb" -lt 10 ]; then
        why="disk ${diskgb}gb free, under 10"
      elif [ "$bycap" -le 0 ]; then
        why="all $max_agents agent slots busy$capnote"
      else
        why="ram ${freegb}gb free, ${RAM_PER_AGENT}gb per agent, busy=$busy"
      fi
      why="no slot: $why"
      [ "$n_drafts" -gt 0 ] && why="$why; $n_drafts draft(s) waiting"
      # Linear is queried only when a slot exists, so at slots=0 a new ticket is
      # invisible to this gate by design. Say so, or the NO reads as "no work".
      why="$why; linear not read"
    else
      why="slots=$slots, nothing to take"
      [ "$n_drafts" -eq 0 ] && why="$why; no drafts"
      if [ -z "$todo_ids" ]; then
        why="$why; linear Todo empty for ${TIER1:-<no tier set>}"
        [ "$ALLOW_UNASSIGNED" = 1 ] || why="$why, unassigned off"
        [ "$ALLOW_BACKLOG" = 1 ] || why="$why, backlog off"
      elif [ "$hash" = "$prev" ]; then why="$why; same todo ids as last tick"; fi
    fi
    NOREASON="$why"
    [ -n "$notes" ] && NOREASON="$NOREASON; notes: $notes"
    [ "$hash" != "$prev" ] && NOREASON="$NOREASON; board changed, nothing actionable"

    # A changed hash with no work is not work. The fixed-interval mode still
    # shows the block below — the model is awake anyway and the numbers are
    # free. The waiter must not exit on it: CI flipping on a draft it has no
    # slot for would wake the model every few minutes, which is the whole cost
    # --wait exists to remove.
    #
    # Only a probe the MODEL saw may move the state forward. In --wait the
    # quiet probes leave it alone, so a world that changed while the machine
    # was full is still "changed" on the probe that finally wakes.
    [ "$MODE" != once ] && return 1
    if [ "$hash" = "$prev" ]; then
      save_state "$hash"
      return 1
    fi
  fi

  save_state "$hash"

  # --- otherwise: everything the model needs, nothing it does not ---
  echo "load1=$load freegb=$freegb diskgb=$diskgb busy=$busy slots=$slots max=$max_agents$capnote"
  [ -n "$notes" ]           && echo "notes: $notes"
  [ "$hash" != "$prev" ]    && echo "world-changed: yes"
  [ "$n_regate"  -gt 0 ]    && echo "REGATE: $regate"
  [ "$n_feedback" -gt 0 ]   && echo "FEEDBACK: $feedback"
  [ "$n_invalid" -gt 0 ]    && echo "INVALID: $invalid"
  [ "$n_drafts"  -gt 0 ]    && echo "DRAFTS: $drafts"
  [ "$n_stack"   -gt 0 ]    && echo "STACK: $stack"
  [ "$n_restack" -gt 0 ]    && echo "RESTACK: $restack"
  [ "$slots" -gt 0 ] && [ -n "$todo_ids" ] && echo "TODO-CANDIDATES: $todo_ids (from ${todo_source:-Todo})"
  [ "$queue_stale" = yes ]  && echo "queue: stale, rebuild before 2d"
  return 0
}

# seconds -> "45s" / "12m", so a short test does not report "0m"
dur() { [ "$1" -lt 60 ] && echo "${1}s" || echo "$(( $1 / 60 ))m"; }

# --- one probe, the fixed-interval mode ---
if [ "$1" != "--wait" ]; then
  probe || echo "NO - $NOREASON"
  exit 0
fi

# --- block until there is work, the event-driven mode ---
# Print a heartbeat when the CAUSE changes, and once every 10 minutes anyway.
# The dedup key drops the digits: load and free memory drift on every probe, so
# a literal comparison prints every line and the trace is unreadable. What the
# user needs to see is "still the load" turning into "still the ram", plus a
# pulse often enough to prove the waiter is alive.
MODE=wait
[ -n "$2" ] && WAIT_MAX="$2"
started=$(date +%s)
echo "waiting for work - probe every ${WAIT_INTERVAL}s, give up after $(dur $WAIT_MAX)"
lastkey=""; lastprint=0
while :; do
  if probe; then
    echo "--- woke after $(dur $(( $(date +%s) - started ))) ---"
    exit 0
  fi
  key=$(printf '%s' "$NOREASON" | tr -d '0-9.')
  if [ "$key" != "$lastkey" ] || [ $(( $(date +%s) - lastprint )) -ge 600 ]; then
    echo "$(date -u +%H:%MZ) NO - $NOREASON"
    lastkey="$key"; lastprint=$(date +%s)
  fi
  now=$(date +%s)
  if [ $(( now - started )) -ge "$WAIT_MAX" ]; then
    # Never wait forever. A bounded waiter that dies costs one idle turn; an
    # unbounded one that dies costs the whole night.
    echo "--- still nothing after $(dur $(( now - started ))), re-arm ---"
    exit 0
  fi
  sleep "$WAIT_INTERVAL"
done
