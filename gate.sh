#!/bin/bash
# One gate for the whole tick. Prints a "NO" line with its reason when there is
# nothing for the model to do, otherwise prints a compact context block.
#
# Two modes:
#   gate.sh            one probe, print, exit — for a fixed-interval loop.
#   gate.sh --wait [s] block until there IS work, then print and exit — for an
#                      event-driven loop. Run it with run_in_background: the
#                      exit is what wakes the model, so a quiet night costs no
#                      turns at all instead of one every 5 minutes.
#
# Why a state hash: 94 consecutive ticks one night printed the same numbers and
# changed nothing. The model only needs to wake when the *world* changed, not
# when the clock did.
#
# Two systems, one gate. GitHub carries the code state — draft/promoted,
# mergeable, CI — read through `gh` as always. Linear carries the conversation:
# human feedback arrives as ticket comments, and the loop's answers are 🌙
# thread replies. The gate polls Linear on a persisted updatedAt watermark:
# one list_issues call per probe answers "did anything move", and only the
# tickets that moved get their comments fetched (in parallel). A quiet probe
# costs one subprocess (~0.8s); a busy one two or three seconds. GitHub
# comments are not read at all, by design — steering lives on the ticket.
#
# Failure discipline, in one sentence: when anything on the Linear side fails,
# NOTHING advances — no watermark, no pending prune — the GitHub half of the
# block still prints in full, and the error wakes the model once and is then
# damped, because an expired token at 01:00 must neither swallow a comment nor
# burn a turn a minute until morning.

# --- config: put your values in .env next to this file (gitignored; see .env.example) ---
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SELF/.env" ] && set -a && . "$SELF/.env" && set +a
REPO="${LO_REPO:-/path/to/your/repo}"
BASE="${LO_BASE:-dev}"
TEAM="${LO_TEAM:-Your Team}"        # Linear team name
PREFIX="${LO_PREFIX:-XXX}"          # ticket id prefix, e.g. PROJ
TIER1="${LO_TIER1:-}"               # preferred assignee DISPLAY name (unassigned always eligible)
TIER2="${LO_TIER2:-}"               # fallback assignee display name
RAM_PER_AGENT="${LO_RAM_PER_AGENT:-2.5}"
# Hard ceiling on concurrent agents, whatever the RAM math allows.
MAX_AGENTS_CAP="${LO_MAX_AGENTS:-4}"
WAIT_INTERVAL="${LO_WAIT_INTERVAL:-60}"   # --wait: seconds between probes
WAIT_MAX="${LO_WAIT_MAX:-2400}"           # --wait: give up and let the model re-arm
# Where the gate keeps its state files. Overridable so a test run of a new
# gate never clobbers the live loop's watermark and hash.
STATE_DIR="${LO_STATE_DIR:-$HOME/.claude/linear-orchestrator}"
# Ticket statuses, by ROLE — names matter for what a status means to the loop.
# Scope (which tickets the loop listens on at all) is matched by status TYPE,
# not name, so a workspace with extra columns ("Shipped" beside "Done", a
# renamed anything) never silently falls out of the ledger: unstarted, started
# and completed types are in scope; backlog, triage, canceled and duplicate
# types are not.
READY_STATUS="${LO_READY_STATUS:-Todo}"
HUMAN_STATUS="${LO_HUMAN_STATUS:-In Progress}"
MERGED_STATUS="${LO_MERGED_STATUS:-In review}"
# Two floors keep history from reading as instructions. The rolling one drops
# human comments older than N days; the absolute one (SET IT TO THE MOMENT OF
# CUTOVER) drops everything from before the loop answered on Linear at all —
# a re-statused ticket's last-two-weeks of pre-cutover triage chatter carries
# no 🌙 replies and would otherwise flood in as unanswered feedback.
FEEDBACK_MAX_AGE_DAYS="${LO_FEEDBACK_MAX_AGE_DAYS:-14}"
FEEDBACK_SINCE="${LO_FEEDBACK_SINCE:-1970-01-01T00:00:00Z}"
# Whose comments steer the loop, comma-separated, case insensitive. Entries
# may be Linear display names OR member UUIDs — prefer UUIDs where it
# matters: display names are self-editable, so a name is convenience, not
# authentication. Empty means everyone who can comment (also meaning: any
# integration or automation that comments without a leading 🌙 reads as a
# person — set this list if your workspace has such apps).
# MERGE_AUTHORS is the stricter list for the one comment that is an action,
# not a steer: "merge". The gate resolves both and stamps each FEEDBACK entry
# with may_merge, so the tick never needs .env at the moment of the check.
FEEDBACK_AUTHORS="${LO_FEEDBACK_AUTHORS:-}"
MERGE_AUTHORS="${LO_MERGE_AUTHORS:-$TIER1}"
# How many moved tickets get their comments fetched per probe. The rest wait:
# the watermark only advances past what was actually fetched.
FETCH_CAP="${LO_FETCH_CAP:-20}"

mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/gate-state"
QUEUE="$STATE_DIR/${PREFIX}-queue.json"
WATERMARK="$STATE_DIR/${PREFIX}-watermark"
PENDING="$STATE_DIR/${PREFIX}-pending.json"
LERR_STAMP="$STATE_DIR/linear-error-wake"
FB_STAMP="$STATE_DIR/feedback-wake"
AC="${AGENT_CODEMODE:-$(command -v agent-codemode 2>/dev/null || echo "$HOME/.local/node/bin/agent-codemode")}"

# The machine/human discriminator, as a jq regex, applied to the FIRST LINE of
# a body — comments and PR bodies alike. The convention is a visible 🌙 at the
# start of the first line; comments written before the convention (and legacy
# GitHub bodies) may carry the HTML-comment form instead. First-line-anchored
# on purpose, on both sides: a human QUOTING a loop line ("🌙 review — …")
# deeper in their text must still read as a human, or their comment is never
# answered — and their PR would read as the loop's own to re-draft and push to.
MOON='^(🌙|<!-- 🌙)'

MODE=once
NOREASON=""

# probe: measure the world once. Prints the context block and returns 0 when
# there is work; prints nothing and returns 1 when there is not, leaving the
# reason in $NOREASON for the caller to print or swallow.
probe() {
  # --- hourly base-branch refresh (refuses, never forces) ---
  stamp="$STATE_DIR/last-fetch"
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
  # A live agent's branch is not work: it is work in progress. Collect the
  # branches here so the PR lists below can drop them, or the waiter exits the
  # instant an agent drafts its own PR and every re-arm spins on the same PR.
  busy=0
  live_branches=""
  for n in 1 2 3 4 5 6 7 8; do
    p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      busy=$((busy+1))
      b=$(git -C ~/.claude/agents/agent-$n branch --show-current 2>/dev/null)
      [ -n "$b" ] && live_branches="$live_branches$b
"
    fi
  done
  held=$(printf '%s' "$live_branches" | jq -Rsc 'split("\n") | map(select(length>0))')

  # --- work already in an agent's hands ---
  # The branch test above cannot see an agent that has not touched its branch
  # yet, and "yet" can be half an hour: an agent reads the ticket and the code
  # long before it cuts a branch or runs `gh pr checkout`. In that window the
  # work looks untaken. (The ticket status cannot close it any more: Todo
  # means "the machine's ball" for the whole working period, not just the
  # wait.) So a dispatch writes the agent's SLOT into a file named after the
  # work — the PR number for work aimed at an existing PR, the ticket id for a
  # fresh ticket — and that work is in hand for precisely as long as the
  # slot's lock is alive. An agent that dies frees its work on the next probe;
  # one that finishes frees it the moment its lock goes. The 10-minute floor
  # covers only the seconds between the spawn and the marker.
  dispatch_dir="$STATE_DIR/dispatched"
  mkdir -p "$dispatch_dir"
  now_s=$(date +%s)
  inhand_raw=""
  for f in "$dispatch_dir"/*; do
    [ -f "$f" ] || continue
    slot=$(cat "$f" 2>/dev/null)
    lp=$(cat ~/.claude/agents/agent-$slot.lock 2>/dev/null)
    if { [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; } \
       || [ $(( now_s - $(stat -f %m "$f") )) -lt 600 ]; then
      inhand_raw="$inhand_raw$(basename "$f")
"
    else
      rm -f "$f"
    fi
  done
  # Numeric names are PR numbers; the rest are ticket ids.
  inhand=$(printf '%s' "$inhand_raw" | jq -Rsc '[ split("\n")[] | select(test("^[0-9]+$")) | tonumber ]')
  inhand_tickets=$(printf '%s' "$inhand_raw" | jq -Rsc '[ split("\n")[] | select(length>0) | select(test("^[0-9]+$") | not) ]')

  max_agents=$(awk -v r=$ramgb -v a=$RAM_PER_AGENT -v c=$MAX_AGENTS_CAP 'BEGIN{m=int(r/a); print (m>c?c:m)}')
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

  # --- the code state, in one gh call ---
  prs=$(gh pr list --repo "$slug" --state open --base $BASE --limit 60 \
    --json number,isDraft,mergeable,body,statusCheckRollup,headRefName 2>/dev/null)
  # A broken gh is itself worth waking for — never wait quietly on it.
  [ -z "$prs" ] && { echo "GATE-ERROR: gh pr list failed"; return 0; }

  verdicts=$(printf '%s' "$prs" | jq -c --arg pfx "$PREFIX" --arg moon "$MOON" '[ .[] | {
      pr: .number, draft: .isDraft, merge: .mergeable, head: .headRefName,
      mine: ((.body // "") | split("\n") | (first // "") | test($moon)),
      ticket: (.headRefName | [match("\($pfx)-[0-9]+"; "ig").string] | (first // "") | ascii_upcase),
      ci: ( [ .statusCheckRollup[]? | select(.conclusion != null
                and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL") ] as $c
            | if   ([ $c[] | select((.name // "") | startswith("Test (shard")) ] | length) == 0 then "not-run"
              elif ([ $c[] | select(.conclusion != "SUCCESS") ] | length) > 0 then "failing"
              else "green" end ) } ] | sort_by(.pr)')

  regate=$(printf '%s' "$verdicts" | jq -c --argjson held "$held" --argjson inhand "$inhand" '[ .[]
            | select(.draft==false and .mine)
            | select(.merge=="CONFLICTING" or .ci=="failing")
            | .pr as $p | select($inhand | index($p) | not)
            | .head as $h | select($held | index($h) | not) ]')
  # .mine matters as much as $held here: a human's draft PR is not the loop's to
  # push commits to.
  drafts=$(printf '%s' "$verdicts" | jq -c --argjson held "$held" --argjson inhand "$inhand" '[ .[]
            | select(.draft and .mine)
            | .pr as $p | select($inhand | index($p) | not)
            | .head as $h | select($held | index($h) | not) | .pr ]')

  # --- the conversation: Linear, on a persisted watermark ---
  feedback=''
  in_scope='[]'
  lerr=""
  if [ -x "$AC" ] || command -v "$AC" >/dev/null 2>&1; then
    wm=$(cat "$WATERMARK" 2>/dev/null)
    if [ -z "$wm" ]; then
      # First run, or a wiped state dir. Look back the whole feedback window
      # and let the capped fetch drain it over successive probes — this is
      # what makes the local files a cache of Linear rather than the record:
      # losing them re-scans, it does not forget.
      wm=$(date -u -v-${FEEDBACK_MAX_AGE_DAYS}d +%Y-%m-%dT%H:%M:%SZ)
      notes="$notes${notes:+; }watermark initialized, rescanning ${FEEDBACK_MAX_AGE_DAYS}d"
    fi
    mj=$("$AC" call linear list_issues \
      --json "{\"team\":\"$TEAM\",\"updatedAt\":\"$wm\",\"orderBy\":\"updatedAt\",\"includeArchived\":true,\"limit\":100,\"fields\":[\"status\",\"statusType\",\"assignee\",\"archivedAt\",\"updatedAt\"]}" \
      --text 2>/dev/null)
    if [ -z "$mj" ] || ! printf '%s' "$mj" | jq -e '.issues' >/dev/null 2>&1; then
      lerr="linear unreachable (token expired? claude mcp login linear)"
    elif [ "$(printf '%s' "$mj" | jq -r '.hasNextPage // false')" = "true" ]; then
      # More than 100 tickets moved since the watermark. The server returns
      # the NEWEST first, so advancing any watermark here would skip the
      # oldest movers forever. Refuse, and let the model decide — this only
      # happens on a workspace-scale event, never on a normal night.
      lerr="over 100 tickets moved since watermark $wm; refusing to advance — clear or advance the watermark deliberately"
    else
      # Everything that moved, oldest first — the order is what lets a capped
      # probe advance the watermark only past what it actually fetched.
      # Scope is matched by status TYPE (see the config comment), and
      # includeArchived is deliberately true: an archived or canceled ticket
      # must be SEEN ONCE so its pending entries can be pruned, or an
      # unanswered entry on it would wake the loop forever.
      sc=$(printf '%s' "$mj" | jq -c '
        ([ .issues[]? | {id, status, statusType, assignee: (.assignee // ""), archivedAt, updatedAt} ]
          | sort_by(.updatedAt)) as $all
        | { inn: [ $all[] | select(.archivedAt == null)
                   | select(.statusType == "unstarted" or .statusType == "started" or .statusType == "completed") ],
            out: [ $all[] | select(.archivedAt != null
                   or (.statusType != "unstarted" and .statusType != "started" and .statusType != "completed")) | .id ],
            last: ($all | last.updatedAt) }')
      in_scope=$(printf '%s' "$sc" | jq -c '.inn')
      out_of_scope=$(printf '%s' "$sc" | jq -c '.out')
      n_in_scope=$(printf '%s' "$in_scope" | jq 'length')
      fetch=$(printf '%s' "$in_scope" | jq -c --argjson cap "$FETCH_CAP" '.[0:$cap]')
      fetched_ids='[]'
      fresh_feedback='[]'
      fetch_ids=$(printf '%s' "$fetch" | jq -r '.[].id')
      if [ -n "$fetch_ids" ]; then
        ctmp=$(mktemp -d)
        for id in $fetch_ids; do
          "$AC" call linear list_comments --json "{\"issueId\":\"$id\",\"limit\":100}" --text \
            > "$ctmp/$id.json" 2>/dev/null &
        done
        wait
        # The rolling floor, then the absolute one — ISO-8601 sorts lexically,
        # so the later of the two is just the bigger string.
        floor=$(date -u -v-${FEEDBACK_MAX_AGE_DAYS}d +%Y-%m-%dT%H:%M:%SZ)
        [ "$FEEDBACK_SINCE" \> "$floor" ] && floor="$FEEDBACK_SINCE"
        for id in $fetch_ids; do
          if ! jq -e '.comments' "$ctmp/$id.json" >/dev/null 2>&1; then
            lerr="comment fetch failed for $id"; continue
          fi
          st=$(printf '%s' "$fetch" | jq -r --arg t "$id" '.[] | select(.id == $t) | .status')
          asg=$(printf '%s' "$fetch" | jq -r --arg t "$id" '.[] | select(.id == $t) | .assignee')
          # Eligibility: on READY tickets within the assignee tiers (or
          # unassigned) every comment steers the machine — that is what the
          # status means. Everywhere else — human-side statuses, and READY
          # tickets assigned outside the tiers, which the loop may never
          # work — the ticket is only the loop's if the loop has spoken on
          # it (a 🌙 comment exists: the pickup note, the review and the
          # promotion comment guarantee one on every worked ticket). Without
          # this, two teammates discussing their own ticket would wake the
          # loop into a conversation that is none of its business.
          eligible=no
          if [ "$st" = "$READY_STATUS" ]; then
            if [ -z "$asg" ] || [ "$asg" = "$TIER1" ] || [ "$asg" = "$TIER2" ]; then eligible=yes; fi
          fi
          # A thread is unanswered when its newest ALLOWED human comment is
          # newer than its newest 🌙 reply. "Allowed" matters inside the
          # thread too: an unlisted bystander replying "+1" after a listed
          # author's steer must not mask the steer — the newest comment that
          # counts is the newest one from someone who may steer.
          #
          # may_merge is true when the thread holds an unanswered comment
          # from a MERGE_AUTHORS member (matched by UUID or display name) —
          # resolved HERE because the tick has no .env at the moment it reads
          # a "merge" comment. 2a still verifies the command comment itself.
          fb=$(jq -c --arg t "$id" --arg eligible "$eligible" --arg floor "$floor" \
                     --arg moon "$MOON" --arg allow "$FEEDBACK_AUTHORS" --arg mauth "$MERGE_AUTHORS" '
            def ismoon: ((.body // "") | split("\n") | (first // "") | test($moon));
            def csv($s): ($s | ascii_downcase | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0)));
            def inlist($l): ( ((.author.name // "") | ascii_downcase) as $w
              | (.author.id // "" | ascii_downcase) as $i
              | (($l | index($w)) != null) or (($l | index($i)) != null) );
            (csv($allow)) as $who | (csv($mauth)) as $mm
            | ([ .comments[]? | select(ismoon) ] | length > 0) as $loopspoke
            | if ($eligible != "yes") and ($loopspoke | not) then [] else
              ( [ .comments[]? ] | group_by(.parentId // .id) | map(
                ( [ .[] | select(ismoon) ] | max_by(.createdAt) ) as $mn
                | ( [ .[] | select(ismoon | not)
                      | select(($who | length) == 0 or inlist($who)) ] | max_by(.createdAt) ) as $hum
                | select($hum != null)
                | select($hum.createdAt > $floor)
                | select($mn == null or $mn.createdAt < $hum.createdAt)
                | ([ .[] | select(ismoon | not) | select(inlist($mm))
                     | select(.createdAt > $floor)
                     | select($mn == null or .createdAt > $mn.createdAt) ] | length > 0) as $mmord
                | { ticket: $t, thread: ($hum.parentId // $hum.id), comment: $hum.id,
                    who: $hum.author.name, who_id: ($hum.author.id // ""), at: $hum.createdAt,
                    may_merge: $mmord } ) )
              end' "$ctmp/$id.json" 2>/dev/null)
          if [ $? -ne 0 ] || [ -z "$fb" ]; then
            lerr="feedback parse failed for $id"; continue
          fi
          fetched_ids=$(printf '%s' "$fetched_ids" | jq -c --arg t "$id" '. + [$t]')
          fresh_feedback=$(printf '%s\n%s' "$fresh_feedback" "$fb" | jq -cs 'add')
        done
        rm -rf "$ctmp"
      fi

      if [ -z "$lerr" ]; then
        # Pending survives the watermark. An unanswered thread stays in the
        # file until a later fetch of that ticket shows it answered — which
        # happens naturally, because the ack bumps the ticket's updatedAt.
        # Prune only what this probe actually learned about: the tickets it
        # fetched (recomputed fresh) and the tickets it saw leave scope.
        # Carried-forward entries get their may_merge re-checked against the
        # CURRENT MERGE_AUTHORS — revoking someone's merge authority must
        # revoke their already-stamped orders too.
        prev_pending=$(cat "$PENDING" 2>/dev/null); [ -z "$prev_pending" ] && prev_pending='[]'
        feedback=$(jq -cn --argjson prev "$prev_pending" --argjson fresh "$fresh_feedback" \
                          --argjson f "$fetched_ids" --argjson gone "$out_of_scope" --arg mauth "$MERGE_AUTHORS" '
          def csv($s): ($s | ascii_downcase | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0)));
          (csv($mauth)) as $mm
          | ([ $prev[] | select(.ticket as $t | ($f | index($t)) or ($gone | index($t)) | not)
              | if .may_merge == true
                then .may_merge = ((($mm | index(((.who // "") | ascii_downcase))) != null)
                                or (($mm | index(((.who_id // "") | ascii_downcase))) != null))
                else . end ] + $fresh)
          | unique_by(.comment)')
        printf '%s' "$feedback" > "$PENDING"
        # Watermark: past everything seen when nothing was capped; only past
        # the last fetched ticket when the probe hit the fetch cap.
        if [ "$n_in_scope" -gt "$FETCH_CAP" ]; then
          new_wm=$(printf '%s' "$fetch" | jq -r 'last.updatedAt // empty')
          notes="$notes${notes:+; }linear catch-up: $n_in_scope moved, fetched $FETCH_CAP oldest"
        else
          new_wm=$(printf '%s' "$sc" | jq -r '.last // empty')
        fi
        [ -n "$new_wm" ] && printf '%s' "$new_wm" > "$WATERMARK"
      fi
    fi
  else
    lerr="agent-codemode CLI not found"
  fi

  # On any Linear failure the ledger is the last good pending file — stale but
  # true, never pruned by a failed probe — and drift is skipped. The GitHub
  # half of the block below prints either way: a dead token must not blind the
  # gate to a conflicting promoted PR it can see with gh alone.
  [ -z "$feedback" ] && feedback=$(cat "$PENDING" 2>/dev/null); [ -z "$feedback" ] && feedback='[]'
  n_feedback=$(printf '%s' "$feedback" | jq 'length')

  # --- status drift: the draft bit and the ticket status are one fact ---
  # isDraft ⇔ READY_STATUS, promoted ⇔ HUMAN_STATUS, for every ticket the loop
  # owns. This is the fast path — it sees drift on tickets that moved in
  # Linear this probe; drift born on the GitHub side (a human runs `gh pr
  # ready`, a status write fails) is caught by the WORK_CACHE rebuild, which
  # reconciles every loop PR against its ticket every 30 minutes (SKILL 2b).
  # The tick decides what each direction MEANS — a human dragging a promoted
  # ticket back to READY is a rework order, a failed write after promotion is
  # not; 2b tells them apart before acting.
  # Where one ticket has several loop PRs (a superseded draft beside the live
  # one), the authoritative PR is the newest promoted one, else the newest —
  # a leftover draft must not read as drift against a correctly-promoted
  # ticket.
  drift=$(jq -cn --argjson v "$verdicts" --argjson m "$in_scope" --arg r "$READY_STATUS" --arg h "$HUMAN_STATUS" '
    def apr($t): [ $v[] | select(.mine and .ticket == ($t | ascii_upcase)) ]
      | if length == 0 then null
        else sort_by(.pr) as $s
          | ([ $s[] | select(.draft | not) ]) as $p
          | (if ($p | length) > 0 then ($p | last) else ($s | last) end)
        end;
    [ $m[] | . as $t | apr($t.id) as $pr | select($pr != null)
      | ( if $pr.draft and $t.status == $h then {ticket: $t.id, pr: $pr.pr, is: $t.status, should: $r}
          elif ($pr.draft | not) and $t.status == $r then {ticket: $t.id, pr: $pr.pr, is: $t.status, should: $h}
          else empty end ) ]')
  n_drift=$(printf '%s' "$drift" | jq 'length')

  n_regate=$(printf '%s' "$regate"  | jq 'length')
  n_drafts=$(printf '%s' "$drafts"  | jq 'length')

  # --- Linear ready column, but only when a slot could take it ---
  # Cheap pre-filter (assignee tier + not archived); the model still applies the
  # judgment drop-rules and dedups against open PRs. New candidate -> hash change.
  # Tickets already in an agent's hands (dispatch marker) never reach the line.
  todo_ids=""
  if [ "$slots" -gt 0 ] && [ -z "$lerr" ]; then
    tj=$("$AC" call linear list_issues \
      --json "{\"team\":\"$TEAM\",\"state\":\"$READY_STATUS\",\"includeArchived\":false,\"fields\":[\"assignee\",\"archivedAt\",\"status\"]}" \
      --text 2>/dev/null)
    if [ -n "$tj" ]; then
      todo_ids=$(printf '%s' "$tj" | jq -r --arg t1 "$TIER1" --arg t2 "$TIER2" --arg r "$READY_STATUS" --argjson held "$inhand_tickets" '
        [ .issues[]?
          | select(.archivedAt == null)
          | select(.status == $r)
          | select(.assignee == null or .assignee == "" or .assignee == $t1 or .assignee == $t2)
          | select(.id as $i | $held | index($i) | not)
          | .id ] | sort | join(",")' 2>/dev/null)
    else
      notes="$notes${notes:+; }linear todo query failed"
    fi
    # Subtract the ids the model has already judged un-runnable. They live in
    # QUEUE's `skipped` list, written by the last rebuild — entries may be
    # bare id strings or {id, why} objects; accept both, or a shape drift
    # silently disables the subtraction and revives the wake-storm this
    # exists to prevent (seen on a real run with HYR2-972).
    if [ -n "$todo_ids" ] && [ -f "$QUEUE" ]; then
      skipped=$(jq -r '[.skipped[]? | if type == "string" then . else .id end] | join(",")' "$QUEUE" 2>/dev/null)
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

  # --- Linear failure: wake once, then damp ---
  # The first failed probe wakes the model (it can fix the token); repeats
  # inside the damping window are a NO with the reason, so a dead token at
  # 01:00 costs one turn, not one a minute until morning. Any healthy probe
  # clears the damp.
  lerr_wake=no
  if [ -n "$lerr" ]; then
    last_lerr=$(stat -f %m "$LERR_STAMP" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - last_lerr )) -gt 900 ]; then
      touch "$LERR_STAMP"
      lerr_wake=yes
    fi
    notes="$notes${notes:+; }GATE-ERROR: $lerr; linear state NOT advanced"
  else
    rm -f "$LERR_STAMP"
  fi

  # --- did anything change since last tick? ---
  hash=$(printf '%s|%s|%s|%s' "$verdicts" "$todo_ids" "$feedback" "$drift" | shasum | cut -c1-16)
  prev=$(cat "$STATE" 2>/dev/null)

  # --- decide ---
  work=no
  [ "$n_regate"  -gt 0 ] && work=yes            # acted on even at slots 0
  # Feedback needs no slot to act on: an ack, a status move and a follow-up
  # ticket are all free. Only the rework behind it needs an agent. But it is
  # damped: NEW feedback (hash moved) wakes immediately; feedback the model
  # already saw and could not clear — a deleted ticket's orphan entry, an ack
  # that failed — re-wakes at most every 15 minutes instead of every probe.
  # And while Linear is down the pending ledger is unactionable (an ack could
  # not be posted), so it never counts as work — the single lerr wake covers
  # telling the model.
  if [ -z "$lerr" ] && [ "$n_feedback" -gt 0 ]; then
    last_fb=$(stat -f %m "$FB_STAMP" 2>/dev/null || echo 0)
    if [ "$hash" != "$prev" ] || [ $(( $(date +%s) - last_fb )) -gt 900 ]; then
      work=yes
      touch "$FB_STAMP"
    fi
  fi
  [ "$n_drift"   -gt 0 ] && work=yes            # a status move is free too
  [ "$lerr_wake" = yes ] && work=yes            # first failure in 15m wakes
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
        why="all $max_agents agent slots busy"
      else
        why="ram ${freegb}gb free, ${RAM_PER_AGENT}gb per agent, busy=$busy"
      fi
      why="no slot: $why"
      [ "$n_drafts" -gt 0 ] && why="$why; $n_drafts draft(s) waiting"
      # The ready column is queried only when a slot exists, so at slots=0 a
      # new ticket is invisible to this gate by design. Comments are NOT — the
      # watermark poll runs every probe — so a quiet NO here really does mean
      # no unanswered human.
      why="$why; ready column not read"
    else
      why="slots=$slots, nothing to take"
      [ "$n_drafts" -eq 0 ] && why="$why; no drafts"
      if [ -z "$todo_ids" ]; then why="$why; ready column empty"
      elif [ "$hash" = "$prev" ]; then why="$why; same todo ids as last tick"; fi
    fi
    [ "$n_feedback" -gt 0 ] && why="$why; $n_feedback pending feedback (damped)"
    NOREASON="$why"
    [ -n "$notes" ] && NOREASON="$NOREASON; notes: $notes"
    [ "$hash" != "$prev" ] && NOREASON="$NOREASON; board changed, nothing actionable"

    # A changed hash with no work is not work. The fixed-interval mode still
    # shows the block below — the model is awake anyway and the numbers are
    # free. The waiter must not exit on it: CI flipping on a draft it has no
    # slot for would wake the model every few minutes, which is the whole cost
    # --wait exists to remove.
    #
    # Only a probe the MODEL saw may move the state hash forward. In --wait
    # the quiet probes leave it alone, so a world that changed while the
    # machine was full is still "changed" on the probe that finally wakes.
    # (The watermark is different: it may advance on quiet probes, because
    # the pending file — not the watermark — is the ledger of what is owed.)
    [ "$MODE" != once ] && return 1
    if [ "$hash" = "$prev" ]; then
      printf '%s' "$hash" > "$STATE"
      return 1
    fi
  fi

  printf '%s' "$hash" > "$STATE"

  # --- otherwise: everything the model needs, nothing it does not ---
  echo "load1=$load freegb=$freegb diskgb=$diskgb busy=$busy slots=$slots"
  [ -n "$lerr" ]            && echo "GATE-ERROR: $lerr; linear state NOT advanced, feedback below may be stale"
  [ -n "$notes" ]           && echo "notes: $notes"
  [ "$hash" != "$prev" ]    && echo "world-changed: yes"
  [ "$n_regate"  -gt 0 ]    && echo "REGATE: $regate"
  [ "$n_feedback" -gt 0 ]   && echo "FEEDBACK: $feedback"
  [ "$n_drift"   -gt 0 ]    && echo "DRIFT: $drift"
  [ "$n_drafts"  -gt 0 ]    && echo "DRAFTS: $drafts"
  [ "$slots" -gt 0 ] && [ -n "$todo_ids" ] && echo "TODO-CANDIDATES: $todo_ids"
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
