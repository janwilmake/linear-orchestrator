---
name: linear-orchestrator
description: Nightly orchestrator that turns tracker tickets into reviewed PRs unattended. Runs on a 5-minute loop, spawns one agent per 2.5 GB of free RAM, picks Todo tickets from Linear (a preferred assignee or unassigned first, a fallback assignee second), and spawns `cca` agents on Opus — one to write the code and open a draft PR, a second in a fresh context to review that diff and fix what the review found. The conversation lives in Linear — the ticket carries the body, the screenshots and the review, humans steer by commenting on the ticket, and the ticket status says whose ball it is (Todo = the machine's, In Progress = a human's). Point it at your own repo in the Project settings table. Use when the user says "start the orchestrator", "run the nightly loop", "orchestrate linear", or asks for tickets to be worked through unattended overnight.
---

# linear-orchestrator — unattended nightly ticket runner

Turns ready tickets into reviewed pull requests while nobody watches. One agent
writes the code and stops. A **second agent, in a fresh context, reviews it** and
fixes what that review found — so the reviewer reads the diff cold, without the
assumptions the author argued itself into.

**Two systems, one loop.** GitHub carries the code state: the branch, the
draft/promoted bit, CI, mergeability. Linear carries everything else — the
ticket holds what a PR body used to hold (problem, solution, decisions,
screenshots), the loop's reviews and acks land as ticket comments, and humans
steer by commenting on the ticket. The PR body is two lines: the 🌙 marker and
the ticket link. **GitHub comments are not read at all**, by design.

**Every PR opens as a draft, and stays one until it has earned its way out** —
a review, a fix pass over that review, and a screenshot if a user can see the
change. Draft is therefore the honest signal, and it is mirrored into the
ticket status: what is ready in the morning is what is not a draft, and its
ticket says In Progress. The loop also finishes drafts before it starts
anything new.

It still never merges **on its own judgment**. Two agents of the same model are
still one model, so the review is evidence about care, not about correctness.
The one merge it performs is the one a human explicitly orders with a "merge"
comment on the ticket (2a) — the human decides, the loop executes. The morning
job is to read the tickets, not to fix a broken base branch.

## The status contract

Default Linear statuses only, and each one carries exactly one bit: **whose
ball is it.**

| Status | Meaning | GitHub mirror |
| --- | --- | --- |
| any backlog-type (`Backlog`, `Planned`, …) | Human territory. **The loop never reads or touches it.** | — |
| `Todo` (`READY_STATUS`) | **The machine's ball**: ready to take, being groomed, implemented, reviewed, fixed, conflicting, CI-red — all of it. | draft PR, or none yet |
| `In Progress` (`HUMAN_STATUS`) | **A human's ball**: read the promoted PR, answer a blocker, pick a research option. Always accompanied by a 🌙 comment saying *what*. | promoted PR |
| `In review` (`MERGED_STATUS`) | Merged, on staging, until verified. Human-managed; Linear's git automation sets it on merge. | merged PR |
| `Done` / `Canceled` / `Duplicate` | Human-managed. The loop never sets these. | — |

The invariant: **`isDraft` ⇔ `READY_STATUS`, promoted ⇔ `HUMAN_STATUS`**, for
every ticket the loop owns (the 🌙 in the PR body is the ownership test). The
gate reports the drift it can see cheaply — tickets that moved in Linear since
the last probe — and the `WORK_CACHE` rebuild reconciles **every** loop PR
against its ticket every 30 minutes, which is what catches drift born on the
GitHub side (a human running `gh pr ready`, a status write that failed). The
tick acts on both (2b).

Moving a ticket into `READY_STATUS` is the start signal. The loop claims work
with local dispatch markers, not with the status — a ticket stays `Todo` for
the whole time the machine holds it, so the board reads honestly at 08:00:
Todo = the machine owes you work, In Progress = you owe the machine a look.

**Linear's git automations must be**: draft PR open → No action; PR review
activity → No action; PR or commit merge → `MERGED_STATUS`. The first two
would yank tickets out of `Todo` mid-work; the third is the merged-ticket move
done natively, so the loop never touches post-merge statuses.

## Project settings

Per-user values live in **`.env`** beside this skill — copy `.env.example`, fill
it in, done. It is gitignored, so nothing personal reaches the repo; `gate.sh`
and every tick read it:

| `.env`                | called              | is                                         |
| --------------------- | ------------------- | ------------------------------------------ |
| `LO_REPO`             | `REPO`              | local checkout the agents clone from       |
| `LO_BASE`             | `BASE_BRANCH`       | branch to cut from and target (`dev`)      |
| `LO_TEAM`             | `TRACKER_TEAM`      | Linear team name                           |
| `LO_PREFIX`           | `TICKET_PREFIX`     | ticket id prefix, e.g. `PROJ`              |
| `LO_TIER1` `LO_TIER2` | `ASSIGNEE_TIER_1/2` | preferred / fallback assignee (unassigned always eligible) |
| `LO_RAM_PER_AGENT`    | `RAM_PER_AGENT_GB`  | GB per agent (default `2.5`)               |
| `LO_MAX_AGENTS`       | `MAX_AGENTS_CAP`    | hard ceiling on concurrent agents (default `4`) |
| `LO_READY_STATUS`     | `READY_STATUS`      | the machine's status (default `Todo`)      |
| `LO_HUMAN_STATUS`     | `HUMAN_STATUS`      | the human's status (default `In Progress`) |
| `LO_MERGED_STATUS`    | `MERGED_STATUS`     | the merged status (default `In review`)    |
| `LO_MERGE_AUTHORS`    | `MERGE_AUTHORS`     | comma-separated Linear display names whose "merge" comment is executed; **defaults to `ASSIGNEE_TIER_1` alone**. The gate resolves this and stamps each `FEEDBACK` entry with `may_merge` |
| `LO_FEEDBACK_AUTHORS` | `FEEDBACK_AUTHORS`  | comma-separated Linear display names whose comments steer the loop; empty (default) means everyone who can comment |
| `LO_FEEDBACK_SINCE`   | `FEEDBACK_SINCE`    | **set to the cutover moment**: comments older than it never surface, so pre-cutover triage history cannot read as instructions |
| `LO_FEEDBACK_MAX_AGE_DAYS` | —              | rolling floor on top of that: human comments older than this many days never surface (default `14`) |
| `LO_FETCH_CAP`        | —                   | moved tickets whose comments are fetched per probe (default `20`); the watermark only advances past what was fetched |
| `LO_STATE_DIR`        | —                   | gate state dir override, for testing a gate without touching the live one |

Both author lists accept Linear display names **or member UUIDs**, comma
separated, case insensitive. UUIDs are the secure form: display names are
self-editable by any member, so a name in `MERGE_AUTHORS` is convenience, not
authentication. The gate matches scope by status **type** (unstarted, started
and completed types are listened on; backlog, triage, canceled and duplicate
types never are), so extra or renamed columns cannot silently fall out of the
feedback ledger — the three status *names* above only assign roles.

Fixed, no config: `TRACKER` Linear MCP · `FORGE` GitHub (`gh`) · `AGENT_GUIDE`
your repo's guide (`CLAUDE.md`) · `REVIEW_COMMAND` `/review <PR#>` ·
`DEV_SERVER` Vite on a free port 5200–5299 · `PROD_SURFACES` never write (prod
vars/config, prod data, prod dashboards) · `QUEUE_CACHE` / `WORK_CACHE`
`~/.claude/linear-orchestrator/<PREFIX>-{queue,work}.json` · `MAX_AGENTS` =
`min(MAX_AGENTS_CAP, floor(ram / RAM_PER_AGENT_GB))`.

**Precondition: your repo must have its own agent guide.** The prompt this skill
hands each agent is a dozen short paragraphs *because* `AGENT_GUIDE` supplies the
rest — branching, local checks, e2e testing, security. Point it at a repo with
no such file and you get an unattended Opus agent on
`--dangerously-skip-permissions` with almost no instructions. Write the guide
first.

`RAM_PER_AGENT_GB` is calibrated for a Vite server plus Chrome. A stack that
runs Docker or a local database needs a bigger number — the capacity gate
cannot detect this and will happily over-spawn.

## Writing to Linear — the three rules every writer follows

1. **Every comment starts with a visible `🌙` at the start of its first
   line.** Linear renders HTML comments as literal text (`<!-- 🌙 →`), so the
   invisible GitHub form is garbage there. An unmarked comment on a
   loop-owned ticket is a person talking to the loop — the author field cannot
   help, because the MCP posts as the user.
2. **Long content collapses into `>>>` toggles** — Linear's native collapsible
   sections, which work in descriptions and comments alike. `<details>` does
   NOT work in Linear; it renders as literal text. A blank line follows the
   `>>> Title` line and a bare `>>>` closes the block. A reader scrolling a
   ticket should see section names and human voices, not walls of machine
   prose. A `## Blocked on` notice never collapses.
3. **Edit descriptions with `save_issue`'s `patch` operations**, not full
   rewrites — anchored edits fail loudly if a human moved the text, instead of
   silently clobbering them. Preserve embedded `<issue …>` / `<pull-request …>`
   tags verbatim; Linear auto-creates them from bare ids and URLs.

## Modes

Pick by the argument you were called with.

| Argument      | Mode                                             |
| ------------- | ------------------------------------------------ |
| none, `start` | **Start the loop** — arm the blocking gate.      |
| `tick`        | **One tick** — do the work described below.      |
| `status`      | Report what is running. Spawn nothing.           |
| `stop`        | Stop the loop. Spawn nothing.                    |

---

## Mode: start the loop

1. Confirm the working directory is `REPO`. `cca` clones `$PWD`, so a wrong
   directory clones the wrong repo. If it is wrong, `cd` there first.
2. Delete any stale `QUEUE_CACHE` — a queue left over from a previous night
   names tickets that have since moved. Leave the watermark and pending files
   alone: they are durable records, not caches.
3. Run **one tick immediately**, so the user sees the first agents start rather
   than waiting for proof that it works. That tick builds the queue and fills
   every slot the machine has room for.
4. Then **arm the waiter** — a `gate.sh --wait` that blocks in this session
   until there is something to do, and wakes the model by exiting:

   Bash tool, `run_in_background: true`, `dangerouslyDisableSandbox: true`:

   ```
   bash "<this skill's directory>/gate.sh" --wait
   ```

   The harness re-invokes the model when a backgrounded command exits, so the
   waiter's exit *is* the next tick. It probes every 60s in pure shell — no
   model, no tokens — and prints one line each time its reason changes, so the
   user watches a live shell rather than a scroll of identical ticks. A quiet
   night now costs nothing at all instead of a turn every 5 minutes.

   A probe that cannot reach Linear exits with a `GATE-ERROR` line instead of
   waiting quietly — a deaf gate means unanswered humans now, not just missed
   tickets. On a `GATE-ERROR` wake: fix what it names (usually
   `claude mcp login linear`), or re-arm and let it retry; give up and tell the
   user after a few rounds.

   Add one slow heartbeat as the safety net, because a waiter that dies takes
   the whole loop with it. Invoke the `loop` skill with:

   ```
   /loop 1h /linear-orchestrator tick
   ```

   Do not detach either one with `nohup`, and do not write the ticks to a log
   file the user has to `tail`. The point of running them here is that the loop
   stays visible and the user can interrupt it without hunting for a pid.

5. Tell the user the loop is live, which tickets the first agents took, and how
   to stop it.

Do not gate on the clock. The user starts the loop when they stop working and
stops it in the morning; a hardcoded night window would break every daytime
test run.

---

## Mode: one tick

Five steps. Stop at the first one that says stop, and report why.

### Step 1 — how many agents does the machine have room for?

**This is the first thing every tick does, before the tracker, before the
queue.** Most ticks end here, in one `bash` call and one line — that is what
makes a 5-minute loop cheap to run all night.

**Run the gate, do not inline it.** The one `bash` call this step needs is
`bash "<this skill's directory>/gate.sh"`, **outside the Bash sandbox**
(`dangerouslyDisableSandbox: true`) — `sysctl` and the `~/.claude/` lock files
are denied inside the sandbox (`Operation not permitted`). `gate.sh` does
everything below in one shot — the hourly base-branch refresh, the reaper, the
capacity math, the promoted-PR REGATE check, the **Linear watermark poll**
(one `list_issues` per probe answers "did anything move"; only the moved
tickets get their comments fetched, in parallel, through the `agent-codemode`
CLI, which inherits Claude Code's Linear OAuth — no token and no model) — and
prints either a `NO` line or a compact context block:

```
load1=… freegb=… diskgb=… busy=… slots=N
notes: …                 # a reap or a refused fetch
world-changed: yes
REGATE: [ … ]            # promoted PRs that stopped being mergeable / went red
FEEDBACK: [ … ]          # ticket comment threads no 🌙 reply has answered yet
DRIFT: [ … ]             # tickets whose status disagrees with their PR's draft bit
DRAFTS: [ … ]            # open loop drafts, none of them already in an agent's hands
TODO-CANDIDATES: ID,ID   # eligible ready ids from Linear (only when slots>0)
queue: stale, rebuild before 2d
```

The `NO` line carries its own reason, so a quiet tick still says what it was
quiet about:

```
NO - no slot: ram 2.1gb free, 2.5gb per agent, busy=1; 1 draft(s) waiting; ready column not read
NO - slots=1, nothing to take; no drafts; ready column empty
```

**`ready column not read` is literal.** The gate queries the ready column only
when a slot exists — a ticket the machine cannot start is not worth a
subprocess every 5 minutes — so at `slots=0` a NO says nothing about the
board's Todo column. **Comments are different**: the watermark poll runs on
every probe regardless of slots, so a quiet NO really does mean no unanswered
human. Repeat the reason to the user rather than reporting "no work".

**On a `NO` line, end the tick here** — that is most ticks, and it costs one
line. Report the reason the gate gave, not a bare "nothing to do".

**If the waiter woke this tick, its block is already in the transcript** — read
it, do not run `gate.sh` again. The numbers would only be seconds newer, and a
second run overwrites the state hash the first one just set. Two lines tell you
which case you are in: `--- woke after 21m ---` is real work, and
`--- still nothing after 40m, re-arm ---` is the bounded wait giving up. On the
second one, arm the next waiter and end the tick.

**Every tick ends by arming the next waiter** — see step 5. `--wait` exits on
work only. A hash that changed with nothing actionable behind it keeps the
waiter blocked, because CI flipping on a draft the machine has no slot for is
not worth a turn.
Otherwise act on the block: `slots` is the count for step 2, and
`REGATE`/`FEEDBACK`/`DRIFT`/`DRAFTS`/`TODO-CANDIDATES` are the work.
`TODO-CANDIDATES` is a pre-filtered shortlist for 2d — it applies only the
cheap assignee + not-archived + not-dispatched filter, so you still apply the
judgment drop-rules and dedup against open PRs. `gate.sh` reads its settings
from `.env` (see the settings table); `agent-codemode` must be on `PATH` or at
`~/.local/node/bin/agent-codemode`, or the gate exits with `GATE-ERROR`.

`FEEDBACK`, `REGATE` and `DRIFT` are work at any slot count, because an ack, a
status move, a re-draft and a follow-up ticket need no agent — only the rework
behind them does. Everything `gate.sh` measures and why — the memory math, the
reaper, the `mergeable`/CI classification, the watermark and the pending file,
the traps around `UNKNOWN` and never-run CI — lives in its comments; do not
reproduce it here.

### Step 2 — pick the next `slots` pieces of work

Four kinds of work compete for a slot, and they are strictly ordered. **Fill
slots from the top, and only fall to the next kind when the one above it is
empty:**

1. **Human feedback** — an unanswered comment thread on one of the loop's
   tickets. Below.
2. **De-gate and drift** — a promoted PR that stopped being mergeable or went
   red, and any ticket whose status disagrees with its PR. Below.
3. **Finish a draft** — an open draft PR with leftover work: no review, no fix
   pass after its review, no screenshot on a user-visible change, a conflict, or
   CI that is not green. Below.
4. **Start a ticket** — a fresh ticket from `READY_STATUS`, via `QUEUE_CACHE`.

The order is the whole point. **An open PR is worth more than a new one**: it is
already most of the way to mergeable, a human is waiting on it, and every hour it
sits unreviewed is an hour the branch drifts from `BASE_BRANCH`. Starting a
sixteenth ticket while fifteen drafts sit unreviewed is how a night ends with
forty PRs and nothing a human can read. Human feedback outranks both because a
person spent attention on it, which is worth more than anything the loop
generates on its own.

#### 2a — Act on what a person said

The `FEEDBACK` line names comment threads on the loop's tickets that no 🌙
reply has answered yet — each entry a ticket id, a thread id, the newest human
comment in it, `who` wrote it, and `may_merge`. The gate's rule is ordering,
not existence: **a thread is answered when its newest human comment is older
than its newest 🌙 reply**, so a person replying into an already-acked thread
wakes the loop again, which is exactly right. The gate has already applied
`FEEDBACK_AUTHORS` (when set, only those people steer — everyone else's
comments never reach this line, and never get an ack; say so to the user if
they ask why a comment went unanswered) and both feedback floors.

Take the entries oldest first. Read the thread
(`list_comments(issueId: <ticket>)`), then act:

**First, is it a merge order?** A comment whose trimmed text **starts with the
word `merge`** and contains nothing beyond a short tail ("merge", "merge it",
"merge pls") is a human ordering the merge. A comment that merely *mentions*
merging mid-sentence is ordinary feedback, never a command. For a merge order:

1. **The entry must say `may_merge: true`**, and the command comment itself
   must be one the gate stamped it for. The gate resolves `MERGE_AUTHORS`
   (UUIDs or display names; UUIDs are the secure form — display names are
   self-editable, so a name in this list is convenience, not authentication)
   and sets `may_merge` when the thread holds an unanswered comment from a
   listed member — the tick has no `.env` at the moment of the check, so the
   entry carries the verdict. When reading the thread, make sure the comment
   that says "merge" is a listed member's own, not a bystander's echo beside
   it. A "merge" from anyone else is ordinary feedback: reply 🌙 that merging
   is reserved to the listed people, and execute nothing. This is the one
   place authorship gates an action — a comment can steer work at any listed
   author's word, but a merge lands on the base branch, and the old system
   could not merge at all.
2. Re-check the state via `get_diff(<PR url>)` and the gate's block: the PR is
   promoted (ticket in `HUMAN_STATUS`), `mergeStatus` is ready, CI green on the
   head commit.
3. All green → `merge_diff(<PR url>)`, then a 🌙 thread reply with the result.
   Linear's git automation moves the ticket to `MERGED_STATUS`; do not move it
   yourself.
4. Any check fails → **no merge**, and the 🌙 thread reply says exactly which
   one and what would clear it.

The invariant survives rephrased: the loop never *decides* to merge; it may
*execute* an explicit merge order from a listed human.

**Otherwise route on the ticket's PR state** (the gate's verdicts carry it):

1. **Open PR** — the human is steering the work. Re-draft the PR if it was
   promoted (`gh pr ready --undo <PR#>`), **move the ticket back to
   `READY_STATUS`** — the ball is the machine's again, and the move is part of
   the ack — reply 🌙 in the thread with what you understood and what happens
   next, and dispatch the rework with the comment **quoted verbatim** in the
   prompt.
2. **PR merged or closed** (ticket in `MERGED_STATUS` or done) — the diff has
   shipped and there is nothing to re-draft, so the answer is a ticket rather
   than a branch. Create it in `READY_STATUS` with the comment quoted and the
   old ticket linked, and reply 🌙 with the new id. This is the case worth
   getting right: somebody merges, then leaves a note about work the PR noticed
   but left out of scope, and the loop turns that note into the next night's
   ticket.
3. **Neither** — the comment asks a question or records something the loop
   should know. Reply 🌙 with the answer, leave the status alone, and invent no
   work.

A comment can also say "stop", "leave it", or "this is fine". Reply 🌙 and do
nothing. The loop never argues with a person on their own ticket.

**Every thread gets a 🌙 reply, including the ones that need no work.** The
reply is the only thing the person sees. Without it they cannot tell the
difference between "read and considered" and "never noticed", so a silent no-op
is the one wrong answer. "Noted, nothing to do, and here is why" is a complete
one. Reply **in the thread** (`save_comment` with `parentId`) — a top-level
comment does not mark the thread answered.

**A comment naming numbers is a ticket order.** The ticket's
`>>> Out of scope & Suggestions` section numbers the follow-up work the diff
noticed and deliberately left out, and a research ticket's body ends in a
numbered list of options with `## Blocked on` asking the reader to pick one. So
"make tickets for 2 and 4", or a bare "2" on a research ticket, means exactly
that: read those numbered items out of the ticket, create one ticket each in
`READY_STATUS` with the item quoted verbatim and the source linked, and reply 🌙
with the ids. That numbering is the whole interface between a one-line comment
and the next night's work — quote the item rather than paraphrasing it, and
never renumber a section. When a ticket carries both lists, say in the reply
which one you read.

##### Never create a ticket that already exists

**A comment is not always a person typing.** Other automated loops on this
machine write to the same tickets — the screenless loop relays what a caller
decided on a call, and it opens the tickets for that call itself. (Until that
loop's own update lands, its relay still posts to GitHub PRs, which this loop
no longer reads — cut over both together, or a call's decisions go nowhere.)
Its comments carry no 🌙, so the gate hands them over as human feedback, which
is right: the caller *is* speaking. What is wrong is answering that comment by
opening a ticket the other loop opened one minute earlier.

So, before creating any ticket out of a comment:

1. **Read the comment for ticket ids.** A relay names what it already created —
   the screenless loop marks its comments `☎️` and lists them under
   `Already ticketed:`. Ids in that list are done. Link them in the reply and
   create nothing.
2. **Then search the tracker anyway**
   (`list_issues(team: TRACKER_TEAM, query: "<the subject>", includeArchived: false)`),
   because a relay that forgot to say so, and a person who wrote the same thing
   twice, look identical from here. An open ticket on the same question, created
   in the last few days, is the ticket — reply with its id.
3. Only then create one.

#### 2b — Keep the two systems telling one story, and de-gate what went stale

**The draft bit and the ticket status are one fact written twice**, and every
merge into `BASE_BRANCH`, every human drag and every automation firing can
split them. This step reconciles them — but **the two directions mean opposite
things**, because the status is the surface a human touches. Never blindly set
the status back to what the PR says: one of the two directions is a person
steering.

For each `DRIFT` entry:

- **Promoted PR + ticket in `READY_STATUS`** — almost always a human dragged
  it back, but rule out the one self-inflicted look-alike first: if the
  newest thing on the ticket is the loop's own 🌙 promotion comment, with no
  human comment after it, this is a promotion whose status write failed or
  was undone by nobody — re-apply `HUMAN_STATUS` once and move on rather
  than un-promoting finished work against no one's order. (2c promotes
  status-first precisely to make this rare.) Otherwise it is a rework order,
  the drag-and-drop successor to the old `invalid` label, and it needs no
  words to count. Re-draft the PR (`gh pr ready --undo`) and
  comment 🌙 on the ticket, **first line exactly `🌙 Awaiting steer`**, then:
  read as rework wanted; say in a comment what to change, or drag it back to
  `HUMAN_STATUS` to undo. Record the draft in `WORK_CACHE` as
  `awaiting-steer`. **The comment, not the cache, is the durable record** —
  the cache is rebuilt every 30 minutes and deleted on stop, and a rebuild
  that consulted only the five gates would re-promote this draft against the
  human's standing order (its gates still pass — that is how it got promoted
  the first time). So the rebuild re-derives `awaiting-steer` from the
  ticket: an `🌙 Awaiting steer` comment newer than both the newest human
  comment and the newest commit means exactly that. The state clears when a
  human comment arrives (2a dispatches the rework, and new commits follow) or
  the human drags the ticket forward again.
- **Draft PR + ticket in `HUMAN_STATUS`** — either an automation fired (fix
  the automation: draft-open and review-activity transitions must be
  No action), or a human pulled the ticket to themselves. Set it back to
  `READY_STATUS` **once**, with a 🌙 comment saying why and that dragging it
  to `HUMAN_STATUS` again will be read as "you are taking this over". If the
  same ticket drifts this direction a second time, believe the human: leave
  the status, mark the draft `human-held` in `WORK_CACHE`, and stop working
  it until they hand it back.

**Then REGATE.** For each PR it names:

1. **Skip it if a live agent holds its branch.** Same lock-file check as
   anywhere else — `~/.claude/agents/agent-N.lock` plus
   `git -C ~/.claude/agents/agent-N branch --show-current`. An agent mid-push
   will resolve this itself, and re-drafting under it starts a fight the
   orchestrator loses.
2. **Back to draft**: `gh pr ready --undo <PR#>`, **and the ticket back to
   `READY_STATUS`** — broken means the machine's ball again.
3. **Comment the ticket why**, in one 🌙 sentence: conflicts with
   `BASE_BRANCH`, or CI red on the head commit, and that the loop will fix it
   and re-promote.
4. **Put it in `WORK_CACHE`** as `needs-mergeable`, with an `attempts` count.
5. **If there is a slot, dispatch the fix now** — see the `needs-mergeable`
   prompt. Steps 1–4 need no slot; only this one does.

**Only ever touch PRs the loop itself opened.** The test is the `🌙` marker in
the PR body, which is why the gate's query filters on it. Silently re-drafting
a human's PR is not the loop's business.

**Cap the attempts at 3.** A PR can conflict, get fixed, get promoted, and
conflict again on the next merge; without a cap that is an agent every few
minutes forever. At 3, leave it drafted, say so in the tick report, and let a
human look. `WORK_CACHE` carries the counter.

#### 2c — Finish the drafts

Every PR this loop opens starts as a draft (step 4), written by an agent that
deliberately stopped before reviewing it, and only becomes ready when it has all
five of:

- a review posted on it — a 🌙 review comment **on the ticket**,
- a fix pass over that review, with a 🌙 reply saying what was fixed,
- a screenshot, if it changes anything a user can see — an `uploads.linear.app`
  image **in the ticket description**,
- **`mergeable` that is not `CONFLICTING`** — a PR that cannot merge is not
  ready, whatever else is on it,
- **CI green on the head commit** — every non-skipped check `SUCCESS`, and a
  `Test (shard …)` check present to prove the workflow actually ran.

The last two are re-checked on every tick after promotion too, in 2b, because a
merge into `BASE_BRANCH` can undo either of them at any moment.

**Those five are the only reasons to keep a draft.** Draft means *the loop is
not finished*. It never means "finished, but a human has to do something".

So a PR whose five gates pass but which still needs a person — a manual test no
agent can run, a credential nobody stored, an account that is not connected —
**gets promoted**, with that item as the **opening line** of the 🌙 promotion
comment on the ticket: what is needed, why no agent can do it, and the options.
Do not invent a human-hold state, and never leave such a PR drafted "until
someone looks at it". Drafting it achieves the opposite of the intent: it keeps
the ticket in `READY_STATUS`, which is the one status the person who must act
never reads.

`WORK_CACHE` holds the drafts that are missing one of those, what each is
missing, and in what order to take them. Rebuild it on the same 30-minute
staleness rule as `QUEUE_CACHE`. The code half of the evidence comes from one
`gh` call (`gh pr list --state open --base <BASE_BRANCH> --json
number,title,headRefName,isDraft,commits,files,body` — **all open loop PRs,
not only drafts**); the conversation half from the ticket (`list_comments`,
and `get_issue` for the description) — one pair of reads per PR, so keep the
rebuild on its staleness rule rather than running it every tick.

**The rebuild is also the full status reconciliation.** The gate's `DRIFT`
line only sees tickets that moved in Linear; drift born on the GitHub side —
a human ran `gh pr ready`, a status write failed — never bumps the ticket and
is invisible to it. So while the tickets are open anyway, compare each loop
PR's draft bit against its ticket status and act per 2b's direction rules.
This is what makes "the two systems tell one story" true within 30 minutes of
any split, whichever side it was born on.

For each draft, decide what it still needs. **Check `## Blocked on` first**, and
promote on the spot if it is there — before classifying anything else:

- **blocked** — the **ticket description** carries `## Blocked on` **as a
  heading on its own line, near the top**. Test it as a line that begins with
  the heading (`^## Blocked on`), never as a substring: a ticket that writes
  *about* the convention mentions the words inside a sentence or in backticks,
  and a substring test promotes it unreviewed. Seen on a real run.
  The agent hit something no agent can pass: a credential nobody stored, an
  account nobody connected, a decision only a person can make. **A research
  ticket lands here by design** — its answer is the ticket body and the
  decision it asks for is the blocker, so promote it on the same line, empty
  diff and all. Promote status-first, like the
  ready case: **move the ticket to `HUMAN_STATUS`** with `ASSIGNEE_TIER_1`
  assigned, then **take the PR out of draft** (`gh pr ready <PR#>`),
  unfinished, unreviewed, whatever state the code is in, and comment 🌙 with
  the blocker as the opening line, never inside a toggle.

  This is the one case that promotes without the five gates, and it is the same
  reasoning behind them: draft means *the loop is not finished*, and a blocked
  PR is as finished as the loop can make it. Everything else about it is noise
  until a person acts, so a review would only bury the one line that matters.
  Record it in `WORK_CACHE` as `blocked` and take no further action on it — a
  person unblocks it, and their comment (2a) restarts the work.
- **needs-mergeable** — `mergeable` is `CONFLICTING`, or CI on the head commit
  is `failing`. This one outranks the rest because **it blocks the others from
  being answerable**: GitHub builds a `pull_request` workflow against a merge
  commit of the branch into the base, and it cannot build that commit while the
  branch conflicts — so a conflicted PR does not run CI at all, and its checks
  stay silent rather than red.
  `mergeable == "UNKNOWN"` is **not** this state — it is "ask again next tick".
- **needs-review** — no 🌙 review-shaped comment on the ticket **dated after
  the head commit**. The test is the order, not the mere existence: an agent
  that pushes code and dies before running `/review` leaves a ticket carrying
  an *older* review, and a test for "is there a review?" reads that as done.
  Compare the comment's `createdAt` against `.commits[-1].committedDate`.
- **needs-fix** — a review exists, but no commit after it and no 🌙 reply. The
  mirror image of the case above, and both are found by the same comparison.
- **needs-screenshot** — the PR touches a user-visible file and the ticket
  description carries no `uploads.linear.app` image. A user-visible file means
  a route, a component, or a non-`.server` UI file. That half is deliberately
  generous: it catches PRs whose UI files are incidental, and a false positive
  costs one agent, while a false negative ships an unreviewable UI change.
  Test the whole description, not a heading — the screenshots live beside the
  sentences they prove, in Problem and Solution, so there is no gallery heading
  to key on, and there never should be.
- **awaiting-steer / human-held** — a `🌙 Awaiting steer` (or takeover) ticket
  comment newer than both the newest human comment and the newest commit.
  Re-derive it from the ticket on every rebuild — never trust the old cache
  for it, and never classify such a draft `ready`. Not promotable, not
  workable; a human comment or drag clears it. Skip.
- **ready** — none of the above. Promote it, **status first, PR second**:
  `save_issue` the ticket to `HUMAN_STATUS` with `ASSIGNEE_TIER_1` assigned
  (a human first owes it a look, and an unowned In Progress ticket tells
  nobody who is answerable), and only when that write succeeded run
  `gh pr ready <PR#>`. **If the status write fails, do not promote** — a
  promoted PR beside a `READY_STATUS` ticket is the exact signature of a
  human's rework order (2b), and the loop must never manufacture it against
  itself. Then comment 🌙 on the ticket that it is ready, with anything a
  human still has to do as the opening line, and drop it from the cache. This
  is the only place a PR becomes ready, and it happens on evidence, never on
  an agent's say-so.

Order the rest, after blocked: needs-mergeable first (nothing else on the PR can
be trusted while it cannot merge, and CI cannot even run), then needs-fix (a
posted review with no fix is the most misleading state a PR can be in — it
looks checked and is not), then needs-review, then needs-screenshot. Within a
kind, oldest PR first.

#### 2d — Start a new ticket

Only when 2a, 2b and 2c are all empty. Judging eligibility means reading every
ready ticket's description, and that is by far the most expensive thing a tick
can do. So it happens once and the verdict is cached: `QUEUE_CACHE` holds the
tickets that survived, in the order they should be taken, carrying only what a
spawn needs.

```json
{
  "builtAt": "2026-08-13T02:14:07Z",
  "tickets": [
    { "id": "XXX-431", "branch": "feature/xxx-431-fix-something" }
  ],
  "skipped": [
    { "id": "XXX-433", "why": "prod-only work, moved to In Progress" }
  ]
}
```

The `skipped` shape is a contract: `gate.sh` reads it to keep judged-unrunnable
ids out of `TODO-CANDIDATES` (it accepts bare id strings too, but write the
object form — the `why` is what the morning reads).

`Read` the file and **rebuild it** (below) in exactly two cases: it is missing,
or `builtAt` is more than 30 minutes old. A rebuild is the only way a ticket
created after the loop started ever gets picked up, and 30 minutes is the
longest a new Urgent should wait.

Otherwise use the file as it stands, and read nothing from the tracker at all.
That is the cheap path, and on a 5-minute loop it is most ticks:

- Take the first `slots` entries. Fewer than `slots` entries is not a reason to
  rebuild — take what is there and leave the rest of the slots for the next
  tick.
- An **empty but fresh** queue means there is no eligible work right now. End
  the tick. Do not rebuild to double-check; an empty result is a real answer and
  it is cached deliberately, so that a night with nothing to do costs one file
  read per tick instead of twelve full tracker reads an hour.

Remove entries from the file as you take them, and write it back **before**
spawning. A ticket that stays in the queue after being handed to an agent gets
handed out again on the next tick.

Rebuilds only ever happen on a tick that has somewhere to put an agent, because
step 1 already ended the tick otherwise. Never rebuild the queue just to look
at it.

#### Rebuilding the queue

Read the ready column from `TRACKER`:

```
list_issues(team: TRACKER_TEAM, state: READY_STATUS, includeArchived: false,
            fields: ["identifier","title","description","gitBranchName",
                     "priority","assignee","labels","updatedAt","status"])
```

**`includeArchived` defaults to `true`, so pass `false` explicitly.** An
archived ticket looks exactly like a live one in the result, and nothing in the
row says "archived" unless you asked for `archivedAt`. Treat a non-null
`archivedAt` as a drop.

Note also that `state:` matches the status **type**, not the column name — so
filter the rows to the exact `READY_STATUS` name. **The loop reads exactly one
column, ever.** There is no backlog pass: backlog-type statuses are human
territory, and a ticket nobody moved to `READY_STATUS` is a ticket nobody asked
the machine to do.

You need the title and description to judge eligibility below. The agent needs
neither — it reads the ticket itself. Only the identifier and `gitBranchName`
reach the prompt, and only those reach the file.

**Assignee preference**, strict tiers — exhaust a tier before falling to the
next:

1. `ASSIGNEE_TIER_1`
2. `ASSIGNEE_TIER_2`

Never take a ticket assigned to anyone else.

**Then act on every ticket that this loop must not work**, instead of silently
skipping it. A skip is a fact a human needs to see, and under the status
contract it has a home:

- Its id already appears in an open PR
  (`gh pr list --state open --base <BASE_BRANCH> --json headRefName,title`), or
  in a live dispatch marker — drop it silently; it is already in flight.
- Its only real work is a write to one of the `PROD_SURFACES`, or it needs an
  artifact no agent has: a design file, a customer decision, a credential
  nobody stored, access to an account that is not connected. **Move it to
  `HUMAN_STATUS`** with a 🌙 comment naming the blocker — there is no PR to
  look at, so the comment is the whole payload. That is the truthful status: a
  human has to do something before the machine can. Their comment, or a drag
  back to `READY_STATUS`, restarts it through 2a.

Record the acted-on ids in the queue file's `skipped` list so the gate stops
counting them; the status move is what a human sees.

Skipping is not the same as blocking. A ticket with a vague description is
**fine to take** — grooming and deciding what it meant is the agent's job (see
the prompt). Only move a ticket to `HUMAN_STATUS` when it asks for something no
agent may do, or something no agent can reach.

**A research ticket is work, not a skip.** It asks a question, and the answer is
the deliverable: a ticket body carrying the finding, the numbers behind it, and
a **numbered list of what to do next** — with an empty diff, or close to one,
behind a PR that exists so the branch and the review page exist. Never drop
such a ticket for producing no code, and never invent a diff to justify it.

**Order what is left** by priority (1 Urgent → 4 Low, 0 None last), then oldest
`updatedAt` first, and write the whole ordered list to `QUEUE_CACHE` with a
fresh `builtAt`. The order is the file's order — nothing downstream re-sorts
it. Then take the first `slots` of them.

Write the file even when nothing survives. An empty queue with a fresh
`builtAt` is what buys the next 30 minutes of ticks their cheap path.

If the column yields nothing, write the empty queue, end the tick, and say so
plainly. Do not lower the bar to find work, and never read a backlog column to
find some.

### Step 3 — verify before spawning

Two agents on one piece of work is the expensive failure, and the ticket status
no longer prevents it — a worked ticket stays in `READY_STATUS` by design. The
claim is the **dispatch marker** (step 4) plus the open-PR check, and this step
is the last look before committing a slot. Do this per ticket, all of them
before any spawning.

1. `get_issue(<id>)` and confirm it is **still** in `READY_STATUS` and still
   assigned within the tiers. In the half hour since the queue was built a
   human may have taken it, closed it, or reassigned it. If it moved, drop it,
   take the next entry from the queue, and do not spend a rebuild on this.
2. Check the dispatch dir (`<state dir>/dispatched/<id>`) — a marker whose
   slot is still alive means another tick already took it; drop it.
3. Comment 🌙 on the ticket: picked up by the nightly orchestrator, at what
   time. **No status move, no assignee change** — the board says `Todo`
   because the machine's ball is exactly what it is; the assignee arrives at
   promotion, when a human first owes it a look.

If the ticket comment write fails, do not spawn — Linear is unreachable and the
agent could neither groom nor report.

### Step 4 — spawn the agents

One `cca` call per ticket, from `REPO`, **unsandboxed**, all calls in a single
Bash invocation:

```bash
cca "<the full prompt, see below>" --dangerously-skip-permissions --non-interactive --model opus
```

The three flags are all load-bearing:

- `--dangerously-skip-permissions` — nobody is awake to answer a prompt.
- `--non-interactive` — the window ends its own session and closes once the
  work is pushed, which is what returns the slot to the pool. Without it every
  slot is gone after four tickets.
- `--model opus` — resolves to Opus 5. The tickets need judgment, not typing.

**Write the dispatch marker in the same Bash call as the spawn — one marker per
handle the work has.** A fresh ticket gets its ticket id; work aimed at an
existing PR gets the PR number **and** the ticket id (2a rework has the ticket
back in `READY_STATUS`, and without the ticket marker the next rebuild would
hand it out again):

```bash
# <state dir> is LO_STATE_DIR, default ~/.claude/linear-orchestrator
echo "<slot>" > <state dir>/dispatched/<TICKET-ID>
echo "<slot>" > <state dir>/dispatched/<PR#>     # when a PR exists
```

`cca` prints the slot it took (`agent-1 -> /Users/admin/.claude/agents/agent-1`),
so read it from that output and write the number.

The gate's live-branch test cannot see an agent that has not touched its branch
yet, and "yet" can be half an hour — an agent reads the ticket and the code
long before it cuts a branch or runs `gh pr checkout`. In that window the work
looks untaken, the waiter wakes on it, and a second agent lands on the same
job. The marker closes it: `gate.sh` treats the work as in hand for exactly as
long as that slot's lock is alive, then deletes the marker itself. So a
dispatch needs no cleanup, an agent that dies frees its work on the next probe,
and one that finishes frees it the moment its lock goes.

If the `cca` call fails, **delete the markers you just wrote** before ending
the tick — the ticket is still in `READY_STATUS`, so the next rebuild finds it
on its own.

Read `~/.claude/skills/multiclaude/SKILL.md` if anything about `cca` is
unclear. Two rules from it that bite here: **there is no name argument**, and
`node_modules` is a symlink into the user's real checkout, so no agent may run
`npm install`.

### Step 5 — report and end the tick

State, in a line or two: the resource numbers, what was taken and of which kind
(feedback / drift / de-gate / draft-finish / new ticket), the agent slots, any
PR promoted out of draft, and how many entries are left in each cache. Then
stop. Twelve of these an hour is fine; twelve paragraphs an hour is not.

**Report what landed, not what was dispatched.** "Spawned on agent-2" is not a
result — a spawned agent that dies before posting leaves a ticket looking
exactly like one that was never dispatched. Every few ticks, check the tickets
whose agents have since exited and say plainly how many actually came out with
the review and the fix pass on them. A run that reports fourteen dispatches and
delivers two is worse than one that reports two, because the first hides the
failure until morning.

`cca` agents are independent sessions. **They do not report back.** Never wait
on one, and never describe what it produced — the next tick, or the morning,
finds out by reading the ticket.

**Then arm the next waiter**, as the last act of the tick — `gate.sh --wait`,
backgrounded and unsandboxed, exactly as in "start the loop". Skip this and the
loop falls back to the hourly heartbeat and looks stalled. Arm one waiter, never
two: a second waiter is a second wake for the same work, and both would spawn
against the same free slot.

### Keep the tick cheap — the loop runs in the user's session

The loop runs in the foreground so the user can watch it, which means every tick
adds to one transcript. The tick has to stay small, or the twelfth hour costs
far more than the first:

- **One or two lines of output per tick.** Step 1 ends most ticks, and it ends
  them in a single line. Never write a paragraph about a tick that did nothing.
- **Let the waiter hold the quiet hours.** A tick that only reports "nothing
  changed" is a tick that should not have happened.
- **Project `gh` output with `--jq`** instead of pulling whole PR payloads into
  context, and read ticket comments only for the tickets the gate named.
- **Read no ticket descriptions on a spawning tick** — that is what
  `QUEUE_CACHE` is for.

A tick also keeps nothing in its head, which is what makes the loop safe to
interrupt: the claim is the dispatch marker, the work is in the two caches, the
feedback ledger is the gate's pending file, the agents are the lock files. So
compaction, a `/clear`, or a stopped and restarted loop loses nothing — the
next tick reads the same state off disk, GitHub and the tracker.

---

## The agent prompt

**Say only what the agent cannot get for itself.** It boots in a full copy of
`REPO`, so `AGENT_GUIDE` loads on its own — branching, local checks, testing
every PR end to end, English-only, migrations, security. And it has every MCP
server this session has, `TRACKER` included. It fetches the ticket. Do not
paste the description, the title or the URL: the identifier is enough, and a
pasted copy goes stale the moment somebody edits the ticket.

Restating any of that is not harmless padding. A second copy of a rule that
changes on someone else's schedule *overrides* what the agent correctly knew.

So the whole prompt is the ticket id, the branch name, and the things that are
true only here:

> Work ticket **`<TICKET_PREFIX>-###`** end to end, unattended — read it in
> Linear. You boot in a `cp -Rc` copy of the working checkout, which may be on
> another branch and carry its uncommitted files, so cut your branch from a
> clean, current base: `git fetch origin && git checkout -f -B <gitBranchName>
> origin/<BASE_BRANCH>`. That `-f` is the one place you discard uncommitted
> changes despite CLAUDE.md — your copy is throwaway and the real checkout keeps
> every change, so nothing is lost. Nobody is awake, so never stop to ask. Where
> CLAUDE.md wants confirmation, that means **do not do it**: no merge, no push
> to `dev`/`main`, no write to production. Production steps go in the
> `>>> Post-merge runbook` section of the ticket.
>
> **The ticket is the document.** Everything a PR body used to carry lives in
> the ticket description, and you keep it current as you work. Its shape, top
> to bottom: the PR link line, `## Blocked on` if there is one (never
> collapsed), then collapsible sections — `>>> Human input (verbatim)`,
> `>>> Grounded ticket`, and then the sections your repo's PR template names
> (Problem, Solution, Decisions, Out of scope & Suggestions, and the rest),
> each a `>>>` toggle with a blank line under the title line. Edit with
> `save_issue`'s `patch` operations, never a full rewrite — a human may be
> editing the same description — and preserve any embedded `<issue …>` /
> `<pull-request …>` tags verbatim.
>
> **Groom the ticket first.** If the description has no
> `>>> Human input (verbatim)` section, restructure it before you write any
> code: the exact original text the human wrote goes verbatim — untouched,
> unformatted — into that toggle, and your rewrite goes into
> `>>> Grounded ticket`: what is actually wrong or wanted, in the reader's
> terms, where to look, what done means. The verbatim section is what makes
> the rewrite safe; a human can always check you against their own words.
>
> Blockers do not stop you. Decide what a careful colleague would defend in the
> morning, prefer the cheapest option to reverse, and record the call in the
> `>>> Decisions` toggle — the question, what you chose, why, the alternative,
> and the cost to reverse. **A Decision needs two or more clear options.** The
> test is whether a careful colleague could have picked the other one: the
> ticket left a gap, and you closed it. Following an instruction is not a
> decision, however deliberate it felt — not from `AGENT_GUIDE`, not from the
> ticket, not from this prompt. So an empty Decisions section is the honest one
> on a ticket that specified everything, and the wrong one on a ticket with
> gaps. If a blocker is genuinely undecidable — a missing credential, an
> account nobody connected — ship what you have with `## Blocked on` as the
> first thing after the link line, above everything, never inside a toggle.
> The orchestrator promotes that PR on its next tick and hands the ticket to a
> human, because the person who can unblock it is the one person `Todo` hides
> it from.
>
> **A ticket that asks a question is answered in the ticket body, not in
> code.** Put the finding there with the numbers behind it, then a **numbered
> list of what to do next** — each entry the work, its cost, and what it would
> break — and a `## Blocked on` line asking the reader to reply with a number.
> The diff stays empty, or near it: do not build the fix, and do not
> manufacture a diff to look busy. The reader comments "do 2", and that number
> becomes the next ticket.
>
> **Open the draft PR before you write any code** — right after you cut the
> branch, with one empty commit if you need something to push
> (`gh pr create --draft`). Its body is exactly two lines, and it never grows:
>
> `🌙 opened by the nightly orchestrator. Not seen by a human.`
> `Everything about this change: <ticket URL>`
>
> Then put the reverse link at the top of the ticket: `get_diff(<PR URL>)`
> returns the review page as `appUrl`, and the first line of the description
> becomes
> `🔗 [PR #<n> on GitHub](<PR URL>/files) · <the bare PR URL>` —
> the `/files` form survives as a real GitHub link, and the bare URL becomes
> Linear's PR chip. (A bare PR conversation URL is always converted to the
> chip; it cannot be kept as a GitHub link.) A PR that exists from the first
> minute is how the orchestrator and a person can both see work in flight, and
> writing the Problem section down before the Solution one is what keeps you
> honest about which one you are solving.
>
> **It stays a draft, and you never take it out.** The orchestrator does that
> later, once the ticket carries a review, a fix pass and a screenshot. Leave
> the ticket's status alone too — `Todo` means the machine is working, and
> your ticket comment is what says which machine.
>
> **Every comment you write on the ticket starts with a visible `🌙` at the
> start of its first line.** Linear renders HTML comments as literal text, so
> never write `<!-- -->` anywhere in Linear. The orchestrator reads unmarked
> comments as a human talking to it, and an unmarked comment of yours would be
> answered as if a person wrote it.
>
> **Screenshots go in the ticket, beside the sentence they prove** — the
> before shot in Problem, the after shot in Solution, never a gallery section.
> Drive the real screen in the browser to get them, then upload through the
> Linear MCP: `prepare_attachment_upload` (issue, filename, `image/png`, exact
> byte size), `curl -X PUT --data-binary` to the signed URL **within 60
> seconds, sending every header it returned verbatim, one file at a time**,
> then embed the returned `assetUrl` in the description markdown:
> `![what it shows](<assetUrl>)`. Never `git add` an image — a screenshot is
> evidence about the diff, not part of it.
>
> Do not run `npm install` — `node_modules` is a symlink to the real checkout.
> Other agents are running dev servers, so take a free port in 5200–5299 and
> point `VITE_BASE_URL` at it.
>
> **You do not review your own work, and you do not fix a review.** Stop once
> the draft PR is open, your commits are pushed and the ticket is current: the
> orchestrator then dispatches a separate agent, in a fresh context, to review
> this diff and to fix what that review finds. Do not run `/review`, and do not
> pre-empt it by re-reading your own diff for faults — a reviewer that inherits
> your reasoning inherits your blind spots, which is the whole reason the
> review is somebody else's job.
>
> **Before you stop, clean up after yourself.** Close every Chrome tab you
> opened — nobody else can: tabs are scoped to your own MCP session, so a tab
> you leave behind outlives you and cannot be closed by the orchestrator or by
> another agent. Then stop the dev server you started. Do this as the last
> thing you do, after the ticket is in its final state, so a failure here
> cannot cost you the work.

Write the prompt with the settings resolved, as above — the agent has no copy
of this table. Pass `gitBranchName` verbatim from the tracker rather than
inventing a branch name: it is what makes the tracker link the PR back to the
ticket by itself.

Keep all the paragraphs. Each covers something no file in the copy says: the
no-confirmation rule, the ticket as the document, grooming, Decisions and what
counts as one, a research ticket answered in the body, the PR opened first with
the two-line body, the link line, the draft rule, the 🌙 marker, where the
screenshots go and how they are uploaded, the two `cca` footguns, the
do-not-review rule, and the closing sequence. Everything else the agent already
has.

### The four prompts for finishing a draft (2b and 2c)

Shorter than the ticket prompt: no branching, no grooming, no ticket claim. The
PR exists. Each starts with `gh pr checkout <PR#>`, and each ends with **leave
it a draft** — only the orchestrator promotes, in 2c.

**All four write their comments on the ticket, never on the PR**, each starting
with a visible `🌙`, with the detail inside a `>>>` toggle whose title names
the contents (`🌙 Review — 6 findings, 2 blockers`, `🌙 Fix pass — commit
a1b2c3d, 6 of 6`). A blank line under the toggle title, or the markdown inside
comes out raw. The reader should be able to scroll a ticket and see only the
section names and the human voices.

**All four end with the same teardown, and it is not optional:** close every
Chrome tab you opened and stop the dev server you started, as the last thing
you do. Tabs are scoped per MCP session, so a tab an agent abandons cannot be
closed by the orchestrator or by any other agent — it simply sits there until
Chrome quits. The dev server is worse: it is a detached `npm exec` child, so it
survives the agent's own session and holds 150–200 MB that the capacity gate
never sees. The reaper only catches an agent that dies before its teardown; if
you finish normally, do this yourself.

**needs-review** — the main one, and the reason the implementer stops early.
This agent owns the review, the fixes and the ticket, and it starts by reading
a diff it did not write.

* Say the PR was opened by another agent and has never been reviewed. It must be
  treated as unreviewed work by an unknown author — which is what it is.
* Run `REVIEW_COMMAND` (`/review <PR#>`), whatever that skill is configured to
  do in this repo.
* **The review must land as one 🌙 comment on the ticket** — one comment, top
  to bottom, file/line refs as plain text, the findings inside a `>>>` toggle
  whose title carries the counts. Not a GitHub review, not a PR comment, not
  ten little comments.
* Run it in the foreground: if it dispatches a background subagent, poll it
  rather than idling, because an idle wait ends the session and kills the
  pending review. Then confirm with `list_comments(issueId: <ticket>)` that the
  comment is really there, and write it yourself if it is not. Do not start
  fixing until you have seen it.
* Then **one** fix pass over what it found: every blocker, plus the nits that
  are mechanical and sit inside files the PR already changed. Leave the rest.
  Do not widen the diff, and do not review a second time. Re-run the
  `AGENT_GUIDE` local checks, and re-test in the browser any blocker whose
  proof was a runtime one. Push the fixes as one commit of their own, then
  reply 🌙 **in the review comment's thread**: what was fixed, in which commit,
  and what was left with the reason.
* **Fix the ticket too where the diff has moved past it** — this agent is the
  first reader the work has had, so a description that no longer describes the
  code is its to correct, with `patch` operations. Keep the link line, the
  verbatim section and the `>>> Decisions` toggle; correct what is wrong rather
  than rewriting what is merely terse. **Delete the Decisions entries that
  record no choice** — an entry that only restates an instruction, with no
  second option a colleague could have picked, buries the ones a human must
  read. A `## Blocked on` notice stays open, above the toggles.

**needs-fix** — a review is already on the ticket. Tell the agent where to read
it (`list_comments(issueId: <ticket>)`) and say **do not run the review
again** — a second review on the same diff produces a thinner set of findings
and buries the first. One fix pass, one commit, one 🌙 reply in the review's
thread.

**needs-mergeable** — the branch cannot merge into `BASE_BRANCH`, or CI is red
on its head commit. Say which, and say that this is the only thing to fix.

* **Merge `BASE_BRANCH` in, do not rebase.** `git fetch origin && git merge
  origin/<BASE_BRANCH>`. Rebasing rewrites published history on a branch that
  has an open PR, and CLAUDE.md keeps that for the user.
* Resolve each conflict keeping **both** intents. A conflict means two changes
  disagree, so picking one side wholesale silently reverts the other; if the
  two cannot both hold, that is a Decision to write in a 🌙 ticket comment, not
  a coin toss.
* **Change nothing else.** No refactors, no drive-by fixes, no second review.
  The diff must grow only by the resolution and, if CI was red, by what CI
  named.
* If CI was red, fix what it reported — CLAUDE.md is explicit that a failing
  check is fixed on the branch.
* Re-run the CLAUDE.md section 4 local checks, push, then comment 🌙 on the
  ticket: what conflicted, how it was resolved, and what CI said.

Note that a conflicted PR shows **no CI at all** rather than red CI, so expect
to fix the conflict first and let CI run for the first time afterwards.

**needs-screenshot** — the narrowest one, and it must say so: check out the
branch, start a dev server, drive the changed screen, capture before and after,
upload both through the Linear MCP (`prepare_attachment_upload` → `curl PUT`
within 60 seconds, headers verbatim, one file at a time), and `patch` them into
the ticket's **Problem** (before) and **Solution** (after) sections, each
beside the sentence it is evidence for — **change no code**. An agent that
finds a bug while screenshotting should write it in a 🌙 ticket comment, not
fix it — the diff has already been reviewed, and widening it now invalidates
that review. Never `git add` an image, and the diff must not grow by a single
file. The one legitimate exception is a ticket whose subject genuinely is an
image asset, and that is a ticket, not a screenshot task.

### Why one comment, and one fix pass

Both rules keep the morning readable.

- **One ticket comment, not a GitHub review.** An inline review can leave the
  PR blocked by an unresolved verdict from an account that never returns; its
  line notes vanish when the fix pass rewrites those lines; and scattered notes
  are unreadable as evidence. One comment on the ticket, top to bottom, where
  the person who steers will actually read it.
- **The comment before the fix.** The review comment is the morning's best
  signal — the agent naming faults in its own work. Fix first and that record
  never exists. Order: post, then fix, then reply what you fixed.
- **One fix pass.** Self-review does not converge — each round finds thinner
  blockers until the night ends — and the agent holds its slot the whole time.
- **The reviewer is a different agent, in a different context.** An author
  reviewing its own diff has already argued itself into every choice in it, and
  it re-reads the code with the intent it meant rather than the intent it
  wrote. A fresh context has only the diff, the ticket and the guide — the same
  three things a human reviewer has. It also frees the author's slot the moment
  the draft is open, so the machine holds more work in flight.
- **Fixing does not earn a merge.** Author and reviewer are one model, so "no
  blockers left" carries no weight. A merge happens on a human's explicit
  word — the review page, `merge_diff` from their own session, or a "merge"
  comment (2a) — and never on the loop's.

---

## Mode: status

Report, and change nothing. List the `HUMAN_STATUS` tickets
(`list_issues(team: TRACKER_TEAM, state: HUMAN_STATUS)`) and pair each with its
PR — an In Progress ticket with no promoted PR and no 🌙 blocker comment is
either a human's own work (fine) or a stranded promotion; say which. Then the
machine's side: each open loop draft against its `Todo` ticket, and any
dispatch marker whose slot is dead (the gate will clear it, but say so).

```bash
for n in 1 2 3 4 5 6 7 8; do
  p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    echo "agent-$n busy (pid $p) $(git -C ~/.claude/agents/agent-$n branch --show-current 2>/dev/null)"
  fi
done
gh pr list --state open --base <BASE_BRANCH> --json number,title,headRefName,isDraft
ls ~/.claude/linear-orchestrator/dispatched/ 2>/dev/null
```

Also report `QUEUE_CACHE` and `WORK_CACHE`: how many entries are waiting in
each and how old `builtAt` is, plus the gate's pending file (unanswered
threads). Do not rebuild either — `status` spawns nothing and spends nothing.

## Mode: stop

1. End the repeat: kill the waiter (`TaskStop` on the backgrounded `gate.sh
   --wait`, or `pkill -f "gate.sh --wait"`) **and** stop the `/loop` heartbeat
   in the session that runs it. Both, or the loop restarts itself. The user can
   also interrupt with escape, or just say "stop the orchestrator".
2. Delete `QUEUE_CACHE` and `WORK_CACHE`. Both are caches of a moment that has
   passed, and leaving them means the next run's first tick spawns against a
   stale picture. **Leave the watermark and pending files** — they are the
   durable record of what has been answered, and deleting them re-answers
   nothing but forgets everything.
3. Leave the running agents alone unless the user asks. Each one still has a
   PR to open, and killing its window loses uncommitted work.
4. List the PRs the run produced so the user can read them — or rather, the
   tickets: `gh pr list --state open --base <BASE_BRANCH> --json
   number,title,isDraft,body`, keep the ones whose body carries the 🌙 marker,
   and name each with its ticket.

---

## What goes wrong

The failure modes seen on real runs — a tick that spawns nothing, `slots` stuck
at 0, a promoted PR the user re-drafts, `mergeable: UNKNOWN`, and the rest —
are in [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md). Read it when a run looks
wrong. Parts of it predate the move of the conversation into Linear; the
mechanics it describes (the gate, the caches, the locks) are unchanged.
