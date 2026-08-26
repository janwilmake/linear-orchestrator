---
name: linear-orchestrator
description: Nightly orchestrator that turns tracker tickets into reviewed PRs unattended. Runs on a 5-minute loop, spawns one agent per 2.5 GB of free RAM, picks Todo tickets from Linear (a preferred assignee or unassigned first, a fallback assignee second), and spawns `cca` agents on Opus — one to write the code and open a draft PR, a second in a fresh context to review that diff and fix what the review found. Point it at your own repo in the Project settings table. Use when the user says "start the orchestrator", "run the nightly loop", "orchestrate linear", or asks for tickets to be worked through unattended overnight.
---

# linear-orchestrator — unattended nightly ticket runner

Turns ready tickets into reviewed pull requests while nobody watches. One agent
writes the code and stops. A **second agent, in a fresh context, reviews it** and
fixes what that review found — so the reviewer reads the diff cold, without the
assumptions the author argued itself into.

**Every PR opens as a draft, and stays one until it has earned its way out** —
a review, a fix pass over that review, and a screenshot if a user can see the
change. Draft is therefore the honest signal: what is ready in the morning is
what is not a draft. The loop also finishes drafts before it starts anything new,
and picks up any PR the user marks `invalid` by putting its ticket back in the
ready column for another pass.

It still never merges anything. Two agents of the same model are still one
model, so the review is evidence about care, not about correctness. The morning
job is to read the PRs, not to fix a broken base branch.

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
| `LO_FEEDBACK_SINCE`   | `FEEDBACK_SINCE`    | the day the loop began marking its own comments; nothing older is read as feedback |
| `LO_FEEDBACK_LOGINS`  | `FEEDBACK_LOGINS`   | comma-separated GitHub logins whose comments steer the loop; empty means every non-bot login |

Fixed, no config: `TRACKER` Linear MCP · `FORGE` GitHub (`gh`) · `AGENT_GUIDE`
your repo's guide (`CLAUDE.md`) · `READY_STATUS` `Todo` then `Backlog` ·
`CLAIMED_STATUS` `In Progress` · `INVALID_LABEL` `invalid` · `REVIEW_COMMAND`
`/review <PR#>` · `DEV_SERVER` Vite on a free port 5200–5299 · `PROD_SURFACES`
never write (prod vars/config, prod data, prod dashboards) · `QUEUE_CACHE` /
`WORK_CACHE` `~/.claude/linear-orchestrator/<PREFIX>-{queue,work}.json` ·
`MAX_AGENTS` = `min(MAX_AGENTS_CAP, floor(ram / RAM_PER_AGENT_GB))`.

**Precondition: your repo must have its own agent guide.** The prompt this skill
hands each agent is twelve short paragraphs *because* `AGENT_GUIDE` supplies the
rest — branching, local checks, the PR template, e2e testing, security. Point it
at a repo with no such file and you get an unattended Opus agent on
`--dangerously-skip-permissions` with almost no instructions. Write the guide
first.

`RAM_PER_AGENT_GB` is calibrated for a Vite server plus Chrome. A stack that
runs Docker or a local database needs a bigger number — the capacity gate
cannot detect this and will happily over-spawn.

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
   names tickets that have since moved.
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
capacity math, the promoted-PR REGATE check, and a **Linear ready-column check**
through the `agent-codemode` CLI (which inherits Claude Code's Linear OAuth, so
no token and no model) — and prints either a `NO` line or a compact context block:

```
load1=… freegb=… diskgb=… busy=… slots=N
notes: …                 # a reap, a refused fetch, or a Linear hiccup
world-changed: yes
REGATE: [ … ]            # promoted PRs that stopped being mergeable / went red
FEEDBACK: [ … ]          # comments on the loop's PRs that nobody answered yet
INVALID: [ … ]           # PRs the user labelled invalid
DRAFTS: [ … ]            # open loop drafts, none of them already in an agent's hands
STACK: [ … ]             # of those, the ones whose base is another branch, with that base
TODO-CANDIDATES: ID,ID   # eligible Todo ids from Linear (only when slots>0)
queue: stale, rebuild before 2d
```

The `NO` line carries its own reason, so a quiet tick still says what it was
quiet about:

```
NO - no slot: ram 2.1gb free, 2.5gb per agent, busy=1; 1 draft(s) waiting; linear not read
NO - slots=1, nothing to take; no drafts; linear ready column empty
```

**`linear not read` is literal.** The gate queries Linear only when a slot
exists, so at `slots=0` a ticket somebody just moved to `Todo` is invisible to
it. That is deliberate — a ticket the machine cannot start is not worth a
subprocess every 5 minutes — but it means a `NO` at `slots=0` says nothing about
the board. Repeat that line to the user rather than reporting "no work".

**On a `NO` line, end the tick here** — that is most ticks, and it costs one
line. Report the reason the gate gave, not a bare "nothing to do".

**If the waiter woke this tick, read its block** — do not run `gate.sh` again.
The numbers would only be seconds newer, and a second run overwrites the state
hash the first one just set. Two lines tell you which case you are in:
`--- woke after 21m ---` is real work, and `--- still nothing after 40m, re-arm ---`
is the bounded wait giving up. On the second one, arm the next waiter and end the
tick.

**Read that block from the waiter's output file, by path, every time.** The
harness announces the exit as a task notification carrying that path, and the
notification is not the block — it names the file and says nothing about what is
in it. Open it before doing anything else.

Assuming the block is already in front of you is how a wake gets dropped. The
notification can arrive mid-turn, while something else has your attention: the
user asks a question, another loop's waiter exits, an agent finishes. Answer that
instead and the block is never opened, so a `REGATE` line naming four promoted
PRs that can no longer merge reads, from the outside, exactly like a quiet night.

Seen on a real run: the waiter woke at 12:03 with four conflicted, still-promoted
PRs in one `REGATE` line — the sweep working exactly as designed. The
notification landed mid-turn, the file was never opened, and the four sat
promoted and unmergeable until the user noticed them by hand. The gate was right
and the tick that ignored it was wrong, which is the failure this paragraph
exists to prevent. **A waiter that exits has always produced something worth
reading — that is the only reason it exits.**

**Every tick ends by arming the next waiter** — see step 5. `--wait` exits on
work only. A hash that changed with nothing actionable behind it keeps the
waiter blocked, because CI flipping on a draft the machine has no slot for is
not worth a turn.
Otherwise act on the block: `slots` is the count for step 2, and
`REGATE`/`FEEDBACK`/`INVALID`/`DRAFTS`/`TODO-CANDIDATES` are the work. `TODO-CANDIDATES` is
a pre-filtered shortlist for 2d — it applies only the cheap assignee +
not-archived filter, so you still apply the judgment drop-rules and dedup against
open PRs. `gate.sh` reads its settings from `.env` (see the settings table);
`agent-codemode` must be on `PATH` or at `~/.local/node/bin/agent-codemode`, or
the gate skips Linear and says so in `notes`.

**A `STACK` line means some of those drafts are layers of one stack**, and a stack
cannot be reviewed in an arbitrary order — layer 2 is unreadable before layer 1
lands. Each entry names the layer's `base`, so sort them bottom-up: the layer
based on `BASE_BRANCH` first, then the one based on that layer's head, and so on.
Review and promote them in that order.

The gate lists open PRs **without filtering on base**, which is what makes those
layers visible at all — filtering on `--base dev` made every layer above the
first invisible, so it sat open and unreviewed until a human found it by hand.
`.mine` (the 🌙 marker in the body) is what keeps the wider query to the loop's
own PRs, and PRs targeting `main` are excluded so a release PR is never mistaken
for work.

`FEEDBACK` and `REGATE` are work at any slot count, because an ack, a re-draft
and a follow-up ticket need no agent — only the rework behind them does.

When `slots` is 0 the tick still acts on a `REGATE` line — re-drafting a PR that
can no longer merge needs no agent (the re-draft half of 2b) — then ends. Everything `gate.sh` measures and why —
the memory math, the reaper, the `mergeable`/CI classification, the traps around
`UNKNOWN` and never-run CI — lives in its comments; do not reproduce it here.

### Step 2 — pick the next `slots` pieces of work

Four kinds of work compete for a slot, and they are strictly ordered. **Fill
slots from the top, and only fall to the next kind when the one above it is
empty:**

1. **Human feedback** — an unanswered comment on one of the loop's PRs, open or
   merged, or a PR marked `INVALID_LABEL`. Below.
2. **De-gate** — one of the loop's own promoted PRs that has since stopped being
   mergeable, or whose CI is red. Back to draft, fixed, re-promoted. Below.
3. **Finish a draft** — an open draft PR with leftover work: no review, no fix
   pass after its review, no screenshot on a user-visible change, a conflict, or
   CI that is not green. Below.
4. **Start a ticket** — a fresh ticket from `READY_STATUS`. The original path,
   from `QUEUE_CACHE`.

The order is the whole point. **An open PR is worth more than a new one**: it is
already most of the way to mergeable, a human is waiting on it, and every hour it
sits unreviewed is an hour the branch drifts from `BASE_BRANCH`. Starting a
sixteenth ticket while fifteen drafts sit unreviewed is how a night ends with
forty PRs and nothing a human can read. Human feedback outranks both because a
person spent attention on it, which is worth more than anything the loop
generates on its own.

#### 2a — Act on what a person said

Two signals, one step: the `FEEDBACK` line names comments nobody has answered,
the `INVALID` line names PRs somebody labelled. Both are a human telling the loop
something, and that outranks every conclusion the loop reached on its own.

**How the loop tells a human comment from its own.** It cannot use the author:
every agent posts through the user's own `gh`, so every comment on every PR
carries the user's login. So the loop marks its own instead.

> **Every comment the loop or one of its agents writes on GitHub carries
> `<!-- 🌙 -->` as its first line. On a Linear ticket, start with a visible `🌙`
> instead** — Linear renders HTML comments as literal text (`<!-- 🌙 →`), so
> the invisible form is garbage there. No exception — reviews, fix-pass
> replies, promotion comments, de-gate notices, acks. An unmarked comment on a
> PR the loop opened is a person talking to it.

**The loop's own comments are collapsed. A person's are not.** Every review, every
fix-pass reply and every de-gate notice goes inside a `<details>` whose summary
names what is in it, so the PR page stays readable and the human comments are the
ones that stand open:

```markdown
<!-- 🌙 -->
<details><summary>🌙 Review — 6 findings, 2 blockers</summary>

...the review...

</details>
```

Leave a blank line under the `<summary>` line, or GitHub renders the markdown
inside it raw.

**Four things never collapse**, because a person has to act on them: a
`## Blocked on` notice, the human-action line of a promotion comment, an ack, and
anything a person wrote. When a comment carries both — an ack plus a long
explanation — the answer stays open and the detail goes in the `<details>`.

**How the loop knows it already answered one.** By its own reply, not by a local
file. The reply to comment `<id>` starts with:

```
<!-- 🌙 ack:<id> -->
```

The gate treats that comment as answered from then on. The record therefore lives
on GitHub and survives a deleted cache, a `/clear`, a restart and a compaction.
The id is load-bearing: a bare marker would let an agent's own fix-pass comment
mask a question somebody asked while that agent was working.

**Every comment gets an ack, including the ones that need no work.** The ack is
the only thing the person sees. Without it they cannot tell the difference between
"read and considered" and "never noticed", so a silent no-op is the one wrong
answer. "Noted, nothing to do, and here is why" is a complete one.

**Who counts.** The scan is limited to PRs the loop opened, so two people
reviewing each other's own PR never wakes it. `FEEDBACK_LOGINS` limits it again,
by author: only those GitHub logins steer the loop, and every other comment is
ignored. Leave it empty and any teammate who can read the PR can steer — a
feature on a small team, and a problem on a repo where outsiders comment.

The gate drops the ignored comments before it does anything else, so they never
reach the `FEEDBACK` line and never get an ack. That is the trade: a person
outside the list gets no answer at all. Say so to the user if they ask why a
comment went unanswered.

Take the entries oldest comment first. Read the comment
(`gh api repos/<owner>/<repo>/issues/comments/<id> --jq .body`), then route it on
the PR state the gate reported:

1. **`OPEN`** — treat it exactly like a label. Re-draft the PR
   (`gh pr ready --undo <PR#>`), ack with what you understood and what happens
   next, and dispatch the rework with the comment **quoted verbatim** in the
   prompt. Leave the ticket In Progress if it is already there.
2. **`MERGED` or `CLOSED`** — the diff has shipped and there is nothing to
   re-draft, so the answer is a ticket rather than a branch. Create it in
   `READY_STATUS` with the comment quoted and the PR linked, and ack with the
   ticket id. This is the case worth getting right: somebody merges, then leaves a
   note about work the PR noticed but left out of scope, and the loop turns that
   note into the next night's ticket.
3. **Neither** — the comment asks a question or records something the loop should
   know. Ack with the answer, and invent no work.

A comment can also say "stop", "leave it", or "this is fine". Ack it and do
nothing. The loop never argues with a person on a PR.

**A comment naming numbers is a ticket order.** A PR body's
`## Out of scope & Suggestions` section numbers the follow-up work its author
noticed and deliberately left out. So "make tickets for 2 and 4" means exactly
that: read those numbered items out of the PR body, create one ticket each in
`READY_STATUS` with the item quoted and the PR linked, and ack with the ticket
ids. That numbering is the whole interface between a one-line review comment and
the next night's work — so quote the item into the ticket rather than paraphrasing
it, and never renumber the section.

**A research PR's numbered options work the same way**, and they are the reason
that PR exists. Its body ends in a numbered list of what to do next, and its
`## Blocked on` line asks the reader to pick one. "do 2", "let us go with 3", or
a bare "2" is therefore a start order: read option 2 out of the body, create the
ticket in `READY_STATUS` with the option quoted verbatim and the research PR
linked, and ack with the ticket id. Take the numbers from whichever list the
reader is answering — a research PR's options, or `## Out of scope &
Suggestions` — and when a PR carries both, say in the ack which list you read.

##### Never create a ticket that already exists

**A comment is not always a person typing.** Other automated loops on this
machine write to the same pull requests — the screenless loop relays what a
caller decided on a call, and it opens the tickets for that call itself. Its
comments carry no `🌙`, so the gate hands them over as human feedback, which is
right: the caller *is* speaking. What is wrong is answering that comment by
opening a ticket the other loop opened one minute earlier.

So, before creating any ticket out of a comment:

1. **Read the comment for ticket ids.** A relay names what it already created —
   the screenless loop marks its comments `<!-- ☎️ -->` and lists them under
   `Already ticketed:`. Ids in that list are done. Link them in the ack and
   create nothing.
2. **Then search the tracker anyway**
   (`list_issues(team: TRACKER_TEAM, query: "<the subject>", includeArchived: false)`),
   because a relay that forgot to say so, and a person who wrote the same thing
   twice, look identical from here. An open ticket on the same question, created
   in the last few days, is the ticket — ack with its id.
3. Only then create one.

Seen on a real run: the screenless loop opened HYR2-972 for a research question
at 20:27 and commented the call's decisions on #789; the loop read that comment,
and opened HYR2-973 for the same question at 20:28. Two tickets, one question,
one minute apart. The rest of that answer — the PR back to draft, the rework
dispatched — was right; only the ticket was duplicate work.

##### The `invalid` label — the explicit override

The label still works, and it says something a comment does not: *redo this*. It
needs no words and it survives everything. For each PR the `INVALID` line names:

1. Find the ticket. The branch name carries the id (`feature/<prefix>-431-…`), and
   the PR body links it.
2. **Move the ticket back to `READY_STATUS`** in `TRACKER`. That is what lets it
   be picked up again — the loop reads columns, not PRs.
3. **Convert the PR back to draft**: `gh pr ready --undo <PR#>`. It failed
   review, so it must not sit in the human's ready list.
4. Comment on the PR saying the orchestrator picked the feedback up and the
   ticket is back in `READY_STATUS`.
5. **Remove the label — but only once the rework is actually spawned**:
   `gh pr edit <PR#> --remove-label <INVALID_LABEL>`.

**Spawn the rework on this tick, ahead of any draft** — do not leave the ticket
to be picked up by 2d later, because 2b and 2c sit between here and there and a
backlog of drafts would park human feedback behind thirty machine-generated PRs. Claim
the ticket back to `CLAIMED_STATUS` as in step 3 first. Where several PRs carry
the label, order them by ticket priority.

**The label comes off last, and only for the ones that got a slot.** It is the
only durable record that a reclaim is owed: steps 1–4 are idempotent, so a PR
whose rework could not start this tick must keep its label and be picked up by
the next one. Stripping the label from every labelled PR and then spawning as
many as there are slots loses every reclaim past the first — the ticket sits in
`READY_STATUS` where 2b outranks it, and the user's feedback is silently dropped.

**Read the user's comments before re-running the ticket.** A reclaimed ticket
that gets the same treatment as the first time produces the same PR and gets
marked invalid again. Whatever the user wrote on the PR is context the next
agent needs, so pass it in the spawn prompt — this is the one case where pasting
into the prompt is right, because the comments live on the PR and not in the
ticket the agent reads.

#### 2b — De-gate the promoted PRs that went stale

**Every merge into `BASE_BRANCH` can invalidate a PR that was already promoted.**
This step catches that, and is cheap enough to run on every tick.

Act on the `REGATE` line from step 1. For each PR it names:

1. **Skip it if a live agent holds its branch.** Same lock-file check as anywhere
   else — `~/.claude/agents/agent-N.lock` plus
   `git -C ~/.claude/agents/agent-N branch --show-current`. An agent mid-push
   will resolve this itself, and re-drafting under it starts a fight the
   orchestrator loses.
2. **Back to draft**: `gh pr ready --undo <PR#>`. Draft is the honest signal, and
   this PR is no longer ready.
3. **Comment why**, in one sentence: conflicts with `BASE_BRANCH`, or CI red on
   the head commit, and that the loop will fix it and re-promote.
4. **Put it in `WORK_CACHE`** as `needs-mergeable`, with an `attempts` count.
5. **If there is a slot, dispatch the fix now** — see the `needs-mergeable`
   prompt. Steps 1–4 need no slot; only this one does.

**Only ever touch PRs the loop itself opened.** The test is the `🌙` marker in
the body, which is why the step 1 query filters on it. Silently
re-drafting a human's PR is not the loop's business.

**Cap the attempts at 3.** A PR can conflict, get fixed, get promoted, and
conflict again on the next merge; without a cap that is an agent every few
minutes forever. At 3, leave it drafted, say so in the tick report, and let a
human look. `WORK_CACHE` carries the counter.

#### 2c — Finish the drafts

Every PR this loop opens starts as a draft (step 4), written by an agent that
deliberately stopped before reviewing it, and only becomes ready when it has all
five of:

- a review posted on it,
- a fix pass over that review, with a reply comment saying what was fixed,
- a screenshot, if it changes anything a user can see,
- **`mergeable` that is not `CONFLICTING`** — a PR that cannot merge is not
  ready, whatever else is on it,
- **CI green on the head commit** — every non-skipped check `SUCCESS`, and a
  `Test (shard …)` check present to prove the workflow actually ran.

The last two are re-checked on every tick after promotion too, in 2b, because a
merge into `BASE_BRANCH` can undo either of them at any moment.

**Those five are the only reasons to keep a draft.** Draft means *the loop is not
finished*. It never means "finished, but a human has to do something".

So a PR whose five gates pass but which still needs a person — a manual test no
agent can run, a credential nobody stored, an account that is not connected —
**gets promoted**, with that item as the **opening line** of the promotion comment
— under the `<!-- 🌙 -->` marker, which every comment the loop writes carries:
what is needed, why no agent can do it, and the options. Do not invent a
human-hold state, and never leave such a PR drafted "until someone looks at it".

Drafting it achieves the opposite of the intent: the person who must act is the
one person the draft hides it from. The
PR template's **Needs human verification** section carries the same fact for
whoever reads the diff.

`WORK_CACHE` holds the drafts that are missing one of those, what each is
missing, and in what order to take them. Rebuild it on the same 30-minute
staleness rule as `QUEUE_CACHE`:

```bash
gh pr list --state open --base <BASE_BRANCH> --draft \
  --json number,title,body,files,reviews,comments,commits
```

For each draft, decide what it still needs. **Check `## Blocked on` first**, and
promote on the spot if it is there — before classifying anything else:

- **blocked** — the body carries `## Blocked on` **as a heading on its own line,
  near the top**. Test it as a line that begins with the heading (`grep -E '^## Blocked
  on'`), never as a substring: a PR that writes *about* the convention — a docs change,
  a Decisions entry, this file — mentions the words inside a sentence or in backticks,
  and a substring test promotes it unreviewed. Seen on a real run.
  The agent hit something no
  agent can pass: a credential nobody stored, an account nobody connected, a
  decision only a person can make. **A research ticket lands here by design** —
  its answer is the body and the decision it asks for is the blocker, so promote
  it on the same line, empty diff and all. **Take it out of draft now**
  (`gh pr ready <PR#>`), unfinished, unreviewed, whatever state the code is in,
  and comment with the blocker as the opening line, never inside a `<details>`.

  This is the one case that promotes without the five gates, and it is the same
  reasoning behind them: draft means *the loop is not finished*, and a blocked PR
  is as finished as the loop can make it. Everything else about it is noise until
  a person acts, so a review would only bury the one line that matters. Record it
  in `WORK_CACHE` as `blocked` and take no further action on it — a person
  unblocks it, and their comment (2a) restarts the work.
- **needs-mergeable** — `mergeable` is `CONFLICTING`, or CI on the head commit is
  `failing`. This one outranks the rest because **it blocks the others from being
  answerable**: GitHub builds a `pull_request` workflow against a merge commit of
  the branch into the base, and it cannot build that commit while the branch
  conflicts — so a conflicted PR does not run CI at all, and its checks stay
  silent rather than red.
  `mergeable == "UNKNOWN"` is **not** this state — it is "ask again next tick".
- **needs-split** — **a reviewer read it and said it is too much to review in one
  sitting**, naming the seam. Not a size threshold: this state is only ever
  reached by a judgment from something that read the diff. See *the reviewer
  decides*. See the **needs-split** prompt. A ticket that is genuinely one
  indivisible change is a legitimate answer — the agent says so and the PR keeps
  its size, with the reason in the body.
- **needs-review** — no review-shaped comment from the loop **dated after the
  head commit**. The test is the order, not the mere existence: an agent that
  pushes code and dies before running `/review` leaves a PR carrying an *older*
  review, and a test for "is there a review?" reads that as done. Compare timestamps: `.comments[].createdAt` against
  `.commits[-1].committedDate`.
- **needs-fix** — a review exists, but no commit after it and no reply comment.
  The mirror image of the case above, and both are found by the same comparison.
- **needs-screenshot** — it touches a user-visible file and the body carries no
  screenshot. A user-visible file means a route, a component, or a non-`.server` UI file. That half is
  deliberately generous: it catches PRs whose UI files are incidental, and a
  false positive costs one agent, while a false negative ships an unreviewable
  UI change.

  **A screenshot means a raster image uploaded to GitHub's attachment host** —
  a URL containing `user-attachments`, not ending in `.svg`. Do not accept
  `raw.githubusercontent.com`: that serves files **out of the repository**, so
  matching it would pass a screenshot somebody committed, which is the one
  outcome this must not reward. Do not test for `![` or `<img` alone: CI bots inject `<img>` SVG badges from third-party hosts, and a bare `<img>` reads as a screenshot. `.svg` is the tell: screenshots are PNG or JPEG,
  badges are SVG.

  **Test the whole body, not a heading.** The agent prompts put the before shot in
  Problem and the after shot in Solution rather than in a `## Screenshots` section,
  so there is no heading to key on — and there never was a good one: a heading with
  nothing under it is a lie the test would believe, and an author who pastes an
  image without one has still done the thing.
- **ready** — none of the above. Take it out of draft with `gh pr ready <PR#>`
  and drop it from the cache. This is the only place a PR becomes ready, and it
  happens on evidence, never on an agent's say-so.

Order the rest, after blocked: needs-mergeable first (nothing else on the PR can be trusted
while it cannot merge, and CI cannot even run), then needs-fix (a posted review
with no fix is the most misleading state a PR can be in — it looks checked and is
not), then **needs-split** (a reviewer has already said it cannot be read whole, so
nothing further is worth doing to it until it is re-cut), then needs-review,
then needs-screenshot. Within a kind, oldest PR first.

#### 2d — Start a new ticket

Only when 2a, 2b and 2c are all empty. Judging eligibility means reading every open
ticket's description, and that is by far the most expensive thing a tick can do.
So it happens once and the verdict is cached: `QUEUE_CACHE` holds the tickets
that survived, in the order they should be taken, carrying only what a spawn
needs.

```json
{
  "builtAt": "2026-08-13T02:14:07Z",
  "tickets": [
    { "id": "XXX-431", "branch": "feature/xxx-431-fix-something" }
  ]
}
```

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
                     "priority","assignee","labels","updatedAt"])
```

**`includeArchived` defaults to `true`, so pass `false` explicitly.** An archived
ticket looks exactly like a live one in the result — same status, same priority,
same assignee — and nothing in the row says "archived" unless you asked for `archivedAt`. Pass the flag, and treat a non-null `archivedAt` as a drop.

Note also that `state:` matches the status **type**, not the column name. Asking
for `Backlog` returns every backlog-type status — on this workspace that means
`Planned`, `Ideas` and `To Discuss` as well. Filter to the exact column name you
meant, or the backlog pass quietly takes work from columns nobody triaged.

You need the title and description to judge eligibility below. The agent needs
neither — it reads the ticket itself. Only the identifier and `gitBranchName`
reach the prompt, and only those reach the file.

**Assignee preference**, strict tiers — exhaust a tier before falling to the
next:

1. `ASSIGNEE_TIER_1`
2. `ASSIGNEE_TIER_2`

Never take a ticket assigned to anyone else.

**Then drop every ticket that this loop must not touch:**

- Its id already appears in an open PR:
  `gh pr list --state open --base <BASE_BRANCH> --json headRefName,title`.
  Reading only the ready column catches this in almost every case, because
  step 3 moves a claimed ticket out of it. This check catches the rest — a
  ticket a human dragged back to ready while its PR is still open.
- Its only real work is a write to one of the `PROD_SURFACES`. `AGENT_GUIDE`
  forbids that without the user in the chat, and there is no user at 03:00.
- It needs an artifact no agent has: a design file, a customer decision, a
  credential nobody stored, access to an account that is not connected.
Skipping is not the same as blocking. A ticket with a vague description is
**fine to take** — deciding what it meant is the agent's job (see Decisions
below). Only skip when the ticket asks for something no agent may do, or for
something no agent can reach.

**A research ticket is work, not a skip.** It asks a question, and the answer is
the deliverable: a PR whose body carries the finding, the numbers behind it, and
the options — with an empty diff, or close to one. Never drop such a ticket for
producing no code, and never invent a diff to justify it. A PR that answers the
question and changes nothing is the right outcome, and an empty commit is enough
to open it.

Such a PR is finished the moment the answer is written and a person must pick
what happens next. So it ships **out of draft**, with `## Blocked on` naming the
decision that is owed (2c) — green, unreviewed, waiting on a human, which is
exactly what the ticket asked for.

**The body has to be choosable.** The finding is only half of it; the other half
is a **numbered list of what to do next**, each entry naming the work, its cost,
and what it would break. `## Blocked on` then says which numbers are on offer and
asks the reader to reply with one. That is the whole handover: the person reads
the finding, comments "do 2", and the loop turns that number into the ticket that
starts the work (2a). A research PR that ends in prose with no numbered options
gives the reader nothing to answer, and the answer is the point.

**Order what is left** by priority (1 Urgent → 4 Low, 0 None last), then oldest
`updatedAt` first, and write the whole ordered list to `QUEUE_CACHE` with a
fresh `builtAt`. The order is the file's order — nothing downstream re-sorts it.
Then take the first `slots` of them.

Write the file even when nothing survives. An empty queue with a fresh
`builtAt` is what buys the next 30 minutes of ticks their cheap path.

**If nothing survives, run the same pass again over `Backlog`** — same tiers,
same drop rules, same ordering — and append what survives *after* the `Todo`
entries. Backlog is a real source of work here, not a last resort, but it is
strictly second: a `Todo` ticket always outranks a `Backlog` one regardless of
priority, because somebody deliberately moved it to `Todo`.

Run the backlog pass only when the `Todo` pass yields nothing eligible. An
eligible `Todo` ticket, even one Low-priority ticket, is enough to skip it.

If neither column yields anything, write the empty queue with a fresh `builtAt`,
end the tick, and say so plainly. Do not lower the bar to find work.

### Step 3 — claim it before spawning

Two agents on one ticket is the expensive failure. Claim first, spawn second.
Do this per ticket, all of them before any spawning.

**The tracker is the claim.** `QUEUE_CACHE` is a cache of *candidates*, never a
claim — it is allowed to be up to 30 minutes stale, it is allowed to be deleted
at any moment, and nothing about a ticket's fate may depend on what it says.
The ticket status is the record, it is the thing a human reads at 08:00, and a
local file that disagreed with it would block a ticket silently and forever.

1. `get_issue(<id>)` and confirm it is **still** in `READY_STATUS` and still
   assigned within the tiers. In the half hour since the queue was built a
   human may have taken it, closed it, or reassigned it. If it moved, drop it,
   take the next entry from the queue, and do not spend a rebuild on this.
2. Move the ticket to `CLAIMED_STATUS` **and assign it to `ASSIGNEE_TIER_1`**,
   in one `save_issue`. The status move is `AGENT_GUIDE` §2.8 and is what hides
   the ticket from the next rebuild, which reads only the ready column. The
   assignment is what makes the board readable at 08:00: an In Progress ticket
   with no owner tells nobody who is answerable for the PR. Assign even when the
   ticket came from `ASSIGNEE_TIER_2` — the orchestrator ran it, so it lands
   with `ASSIGNEE_TIER_1`.
3. Comment on the ticket: picked up by the nightly orchestrator, at what time.

If the tracker write fails, do not spawn. An unclaimed ticket handed to an
agent gets handed out again 5 minutes later.

If the `cca` call fails after the status moved, **put the ticket back to
`READY_STATUS`** before ending the tick. Otherwise it sits claimed with no
agent and no PR, and neither the loop nor a human picks it up again. Putting it
back in `QUEUE_CACHE` as well is optional — the next rebuild finds it anyway.

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

**Dispatching work aimed at an existing PR? Write the dispatch marker in the
same Bash call as the spawn** — 2a, 2b and 2c all need it, a fresh ticket has no
PR yet so it does not:

```bash
echo "<slot>" > ~/.claude/linear-orchestrator/dispatched/<PR#>
```

`cca` prints the slot it took (`agent-1 -> /Users/admin/.claude/agents/agent-1`),
so read it from that output and write the number.

The gate's live-branch test cannot see an agent that has not run `gh pr checkout`
yet, and "yet" can be half an hour — an agent sent to answer a question reads the
code long before it touches the branch. In that window the PR looks unattended,
the waiter wakes on it, and a second agent lands on the same PR. The marker
closes it: `gate.sh` treats the PR as in hand for exactly as long as that slot's
lock is alive, then deletes the marker itself. So a dispatch needs no cleanup, an
agent that dies frees its PR on the next probe, and one that finishes frees it
the moment its lock goes.

Read `~/.claude/skills/multiclaude/SKILL.md` if anything about `cca` is
unclear. Two rules from it that bite here: **there is no name argument**, and
`node_modules` is a symlink into the user's real checkout, so no agent may run
`npm install`.

### Step 5 — report and end the tick

State, in a line or two: the resource numbers, what was taken and of which kind
(reclaim / draft-finish / new ticket), the agent slots, any PR promoted out of
draft, and how many entries are left in each cache. Then stop. Twelve of these
an hour is fine; twelve paragraphs an hour is not.

**Report what landed, not what was dispatched.** "Spawned on agent-2" is not a
result — a spawned agent that dies before posting leaves a PR looking exactly
like one that was never dispatched. Every few ticks, check the PRs whose agents
have since exited and say plainly how many actually came out with the review and
the fix pass on them. A run that reports fourteen dispatches and delivers two is
worse than one that reports two, because the first hides the failure until
morning.

`cca` agents are independent sessions. **They do not report back.** Never wait
on one, and never describe what it produced — the next tick, or the morning,
finds out by reading the PR.

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
  context.
- **Read no ticket descriptions on a spawning tick** — that is what `QUEUE_CACHE`
  is for.

A tick also keeps nothing in its head, which is what makes the loop safe to
interrupt: the claim is the ticket status, the work is in the two caches, the
agents are the lock files. So compaction, a `/clear`, or a stopped and restarted
loop loses nothing — the next tick reads the same state off disk and the tracker.

---

## The agent prompt

**Say only what the agent cannot get for itself.** It boots in a full copy of
`REPO`, so `AGENT_GUIDE` loads on its own — branching, local checks, the PR
template, testing every PR end to end, English-only, migrations, security. And
it has every MCP server this session has, `TRACKER` included. It fetches the
ticket. Do not paste the description, the title or the URL: the identifier is
enough, and a pasted copy goes stale the moment somebody edits the ticket.

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
> every change, so nothing is lost. Nobody is awake, so never stop to ask. Where CLAUDE.md wants confirmation, that means **do not do it**: no
> merge, no push to `dev`/`main`, no write to production. Production steps go
> in the Post-merge runbook.
>
> Blockers do not stop you either. Decide what a careful colleague would defend
> in the morning, prefer the cheapest option to reverse, and record the call in a
> `## Decisions` section in the PR body — the question, what you chose, why, the
> alternative, and the cost to reverse.
>
> **A Decision needs two or more clear options.** The test is whether a careful
> colleague could have picked the other one: the ticket left a gap, and you closed
> it. Following an instruction is not a decision, however deliberate it felt —
> not from `AGENT_GUIDE`, not from the ticket, not from this prompt. "The branch
> opened with an empty commit so the draft PR could exist before the code, as
> instructed" is the shape to leave out: one option, no choice, and it spends the
> attention the real decisions need. So an empty Decisions section is the honest
> one on a ticket that specified everything, and the wrong one on a ticket with
> gaps. If a blocker is genuinely undecidable —
> a missing credential, an account nobody connected — ship what you have with
> `## Blocked on` as the **first thing in the body**, above everything, and never
> inside a `<details>`. The orchestrator takes that PR out of draft on its next
> tick, because the person who can unblock it is the one person a draft hides it
> from.
>
> **A ticket that asks a question is answered in the PR body, not in code.** Put
> the finding there with the numbers behind it, then a **numbered list of what to
> do next** — each entry the work, its cost, and what it would break — and a
> `## Blocked on` line asking the reader to reply with a number. The diff stays
> empty, or near it: do not build the fix, and do not manufacture a diff to look
> busy. The reader comments "do 2", and that number becomes the next ticket.
>
> **Open the draft PR before you write any code** — right after you cut the
> branch, with one empty commit if you need something to push. Its body is the
> marker line, whatever heading lines your repo's template puts first, and then a
> `## Problem` section — collapsed, like every section — holding two or three
> sentences on what is actually wrong, in the reader's terms, and the ticket link.
> Nothing else yet. A PR that exists from
> the first minute is how the orchestrator and a person can both see work in
> flight, and writing the problem down before the solution is what keeps you
> honest about which one you are solving.
>
> Then **keep the body current as you go**. By the time you stop, it must satisfy
> the PR template and the PR skills of the repo itself — a body written for the
> first commit is wrong by the fifth, and the body is what the reviewer reads.
> `gh pr edit <PR#> --body-file` beats rewriting it from memory at the end.
>
> **It stays a draft** (`gh pr create --draft`), and you never take it out. The
> orchestrator does that later, once it has a review, a fix pass and a
> screenshot. Start the PR body with:
> `🌙 opened by the nightly orchestrator. Not seen by a human. Read the Decisions section before merging.`
>
> **Start every comment you write on the PR with the line `<!-- 🌙 -->`, and
> every comment on the ticket with a visible `🌙` at the start of the first
> line** — Linear renders HTML comments as literal text, so the invisible form
> shows as garbage there. The orchestrator reads unmarked comments as a human
> talking to it, and an unmarked comment of yours would be answered as if a
> person wrote it.
>
> **Every section of the body is collapsed**, `## Decisions` included. Each one is a
> `<details>` whose `<summary>` is the section name, with a blank line under the
> `<summary>` line or the markdown inside comes out raw. The one exception is a
> `## Blocked on` notice, which never collapses. A person scrolling the PR should
> see a list of section names and open the one they want, not a wall of prose.
>
> **Screenshots are not a section of their own.** If the change is visible to a
> user, the before shot goes in **Problem** and the after shot in **Solution**, each
> beside the sentence it is evidence for. A `## Screenshots` gallery at the bottom
> separates every picture from the claim it proves, which is the opposite of what a
> screenshot is for. Drive the real screen in the browser to get them, and **upload
> them through the GitHub web UI** — open the PR on github.com, edit the body, drop
> the file into the editor so GitHub hosts it. Never `git add` an image: a
> screenshot is evidence about the diff, not part of it.
>
> Do not run `npm install` — `node_modules` is a symlink to the real checkout.
> Other agents are running dev servers, so take a free port in 5200–5299 and
> point `VITE_BASE_URL` at it.
>
> **You do not review your own work, and you do not fix a review.** Stop once the
> draft PR is open and your commits are pushed: the orchestrator then dispatches a
> separate agent, in a fresh context, to review this diff and to fix what that
> review finds. Do not run
> `/review`, and do not pre-empt it by re-reading your own diff for faults — a
> reviewer that inherits your reasoning inherits your blind spots, which is the
> whole reason the review is somebody else's job.
>
> Finally comment the PR link on the ticket, leave it In Progress, and stop.
>
> **Before you stop, clean up after yourself.** Close every Chrome tab you
> opened — nobody else can: tabs are scoped to your own MCP session, so a tab
> you leave behind outlives you and cannot be closed by the orchestrator or by
> another agent. Then stop the dev server you started. Do this as the last thing
> you do, after the PR is in its final state, so a failure here cannot cost you
> the work.

Write the prompt with the settings resolved, as above — the agent has no copy
of this table. Pass `gitBranchName` verbatim from the tracker rather than
inventing a branch name: it is what makes the tracker link the PR back to the
ticket by itself.

Keep all twelve paragraphs. Each covers something no file in the copy says: the
no-confirmation rule, Decisions, what counts as one, a research ticket answered
in the body, the PR opened first, the body kept current, the
marker, every section collapsed, where the screenshots go and how they are
uploaded, the two `cca` footguns, the do-not-review rule, and the closing
sequence. Everything else the
agent already has.

### The five prompts for finishing a draft (2b and 2c)

Shorter than the ticket prompt: no branching, no Decisions section, no ticket
claim. The PR exists. Each starts with `gh pr checkout <PR#>`, and each ends
with **leave it a draft** — only the orchestrator promotes, in 2c.

**All five start every comment they write with the line `<!-- 🌙 -->`** — the
review, the reply, the note about something found on the way. An unmarked comment
is how the loop recognises a person, so an unmarked comment from an agent gets
answered as one (2a).

**And all five collapse what they write**, inside a `<details>` with a summary
that names the contents (`🌙 Review — 6 findings, 2 blockers`, `🌙 Fix pass —
commit a1b2c3d, 6 of 6`). A blank line under the `<summary>` line, or the
markdown inside comes out raw. The reader should be able to scroll a PR and see
only the human voices.

**All five end with the same teardown, and it is not optional:** close every
Chrome tab you opened and stop the dev server you started, as the last thing you
do. Tabs are scoped per MCP session, so a tab an agent abandons cannot be closed
by the orchestrator or by any other agent — it simply sits there until Chrome
quits. The dev server is worse: it is a detached `npm exec` child, so it
survives the agent's own session and holds 150–200 MB that the capacity gate
never sees. The reaper only catches an agent that dies before its teardown; if you finish normally, do this yourself.

**needs-split** — *the reviewer decides.* A reviewer read this PR and said it was
too much to review in one sitting, naming the seam. This agent does **not**
review it; it re-cuts it into a stack so that each layer can be.

**Nothing else puts a PR here.** Not a file count, not a line count, not a
threshold the gate measured. A PR is split because somebody who read it could not
hold it, which is the only test that survives a formatting sweep and a dense
three-file change alike.

* Say the PR is too large for one reviewer to hold, give its file count, and say
  the job is to re-cut it — **not** to change what it does. **The combined diff
  of the stack must equal the original diff.** Anything else is a rewrite wearing
  a split's clothes.
* **Find the seams from the dependency order**, not from the file tree. A layer
  must build and pass its own tests on its own, so a schema change and its
  migration go in the bottom layer, pure modules above that, the routes that call
  them above that, and the UI last. If a layer cannot stand alone, it is in the
  wrong place.
* Use the repo's own stacking tool if it has one — this repo has a `gh-stack`
  skill. **Each layer targets the layer below it, never `BASE_BRANCH`**, except
  the bottom one.
* **Every layer is a draft**, carries the 🌙 marker line, and links the ticket.
  The orchestrator reviews and promotes them bottom-up.
* **Close the original PR last**, after the stack is up and verified, with a
  comment linking every layer. Never close it first: a window where the work has
  no PR is a window where it is lost. If the original carried a review or human
  comments, say in that comment that its history lives there.
* **"This is one indivisible change" is a legitimate answer.** A migration whose
  callers cannot compile without it, or a single generated file, does not split.
  Say so on the PR with the reason, leave it as it is, and the orchestrator
  reviews it whole. Do not manufacture layers to hit a number.

Note what this costs: the stack's layers are invisible to `gh pr list --base`,
which is why the gate no longer filters on base and prints a `STACK` line
instead. Without that, every layer above the first would sit unreviewed.

**needs-review** — the main one, and the reason the implementer stops early. This
agent owns the review, the fixes and the PR body, and it starts by reading a diff
it did not write.

* Say the PR was opened by another agent and has never been reviewed. It must be
  treated as unreviewed work by an unknown author — which is what it is.
* **You may stop and call it unreviewable.** Before anything else, read the whole
  diff. If you cannot hold it in one sitting — too many independent decisions, too
  many unrelated areas, a change you would have to re-read three times to be sure
  of — **say so and stop**. Post one comment naming *why* and *where the seam is*,
  and do not produce a review you would not stand behind. That comment is what
  puts the PR into **needs-split**, and the orchestrator dispatches the split.

  This is a real verdict, not an escape from work, and it is the only honest one
  when it applies: a review of a diff nobody could hold is worse than no review,
  because it *looks* like the PR was checked. Size alone does not decide it —
  four thousand lines of generated code or a formatting pass across two hundred
  files is one decision and reviewable in minutes, while three hundred lines
  spanning auth, tenancy and a migration may not be. **You are the judge because
  you read it; the gate only counts.**

* Run `REVIEW_COMMAND` (`/review <PR#>`), whatever that skill is configured to do
  in this repo.
* **The review must land as one ordinary PR comment** — `gh pr comment <PR#>
  --body …` — not as a GitHub review with comments attached to lines in the diff.
* Run it in the foreground: if it dispatches a background subagent, poll it rather
  than idling, because an idle wait ends the session and kills the pending review.
  Then confirm with `gh pr view <PR#> --json comments` that the comment is really
  there, and write it yourself if it is not. Do not start fixing until you have
  seen it.
* Then **one** fix pass over what it found: every blocker, plus the nits that are
  mechanical and sit inside files the PR already changed. Leave the rest. Do not
  widen the diff, and do not review a second time. Re-run the `AGENT_GUIDE` local
  checks, and re-test in the browser any blocker whose proof was a runtime one.
  Push the fixes as one commit of their own, then reply on the PR: what was fixed,
  in which commit, and what was left with the reason.
* **Fix the PR body too where the diff has moved past it** — this agent is the
  first reader the PR has had, so a body that no longer describes the code is its
  to correct. Keep the 🌙 marker line and the `## Decisions` section; correct what
  is wrong rather than rewriting what is merely terse. **Delete the Decisions
  entries that record no choice** — an entry that only restates an instruction,
  with no second option a colleague could have picked, buries the ones a human
  must read. **Fix the shape as well as
  the content**: every section collapsed in its own `<details>`, `## Decisions`
  included, a blank line under each `<summary>`, and the screenshots moved out of
  any `## Screenshots` section into Problem (before) and Solution (after). A
  `## Blocked on` notice stays open.

**needs-fix** — a review is already on the PR. Tell the agent where to read it
(`gh pr view <PR#> --json comments`, or
`gh api repos/<owner>/<repo>/pulls/<PR#>/comments` for older PRs whose review
landed inline) and say **do not run the review again** — a second review on the
same diff produces a thinner set of findings and buries the first. One fix pass,
one commit, one reply comment.

**needs-mergeable** — the branch cannot merge into `BASE_BRANCH`, or CI is red on
its head commit. Say which, and say that this is the only thing to fix.

* **Merge `BASE_BRANCH` in, do not rebase.** `git fetch origin && git merge
  origin/<BASE_BRANCH>`. Rebasing rewrites published history on a branch that has
  an open PR, and CLAUDE.md keeps that for the user — a force-push here would
  also throw away the review comments' line anchors.
* Resolve each conflict keeping **both** intents. A conflict means two changes
  disagree, so picking one side wholesale silently reverts the other; if the two
  cannot both hold, that is a Decision to write in a PR comment, not a coin toss.
* **Change nothing else.** No refactors, no drive-by fixes, no second review. The
  diff must grow only by the resolution and, if CI was red, by what CI named.
* If CI was red, fix what it reported — CLAUDE.md is explicit that a failing
  check is fixed on the branch.
* Re-run the CLAUDE.md section 4 local checks, push, then comment: what
  conflicted, how it was resolved, and what CI said.

Note that a conflicted PR shows **no CI at all** rather than red CI, so expect to
fix the conflict first and let CI run for the first time afterwards.

**needs-screenshot** — the narrowest one, and it must say so: check out the
branch, start a dev server, drive the changed screen, capture before and after,
edit the before shot into the body's **Problem** section and the after shot into
**Solution** — never a `## Screenshots` section of their own — **change no code**. An agent that
finds a bug while screenshotting should write it in a PR comment, not fix it —
the diff has already been reviewed, and widening it now invalidates that review.

**The image is uploaded through the GitHub web UI, never committed.** Drive
github.com in the browser, open the PR, edit the body, and drop the file into
the editor so GitHub hosts it at `user-attachments` and rewrites the markdown
itself. Say this explicitly in the prompt, because the obvious shortcut for an
agent holding a `.png` and a repo is `git add` — and that ships a screenshot as
a source file, on a branch that is meant to be reviewable code. Two sentences in
the prompt: **never `git add` an image, and the diff must not grow by a single
file.** The one legitimate exception is a ticket whose subject genuinely is an
image asset, and that is a ticket, not a screenshot task.

### Why one comment, and one fix pass

Both rules keep the morning readable.

- **One PR comment, not a GitHub review.** An inline review can leave the PR
  blocked by an unresolved verdict from an account that never returns; its line
  notes vanish when the fix pass rewrites those lines; and scattered notes are
  unreadable as evidence. One comment, top to bottom, file/line refs as text.
- **The comment before the fix.** The review comment is the morning's best
  signal — the agent naming faults in its own work. Fix first and that record
  never exists. Order: post, then fix, then reply what you fixed.
- **One fix pass.** Self-review does not converge — each round finds thinner
  blockers until the night ends — and the agent holds its slot the whole time.
- **The reviewer is a different agent, in a different context.** An author
  reviewing its own diff has already argued itself into every choice in it, and
  it re-reads the code with the intent it meant rather than the intent it wrote.
  A fresh context has only the diff, the ticket and the guide — the same three
  things a human reviewer has. It also frees the author's slot the moment the
  draft is open, so the machine holds more work in flight.
- **Fixing does not earn a merge.** Author and reviewer are one model, so "no
  blockers left" carries no weight; a defensible merge needs a second,
  independent agent, which this file does not do.

---

## Mode: status

Report, and change nothing. Also list the claimed tickets
(`list_issues(team: TRACKER_TEAM, state: CLAIMED_STATUS)`) and pair each with
its PR — a claimed ticket with no open PR and no live agent is stranded, and
this is the only place that shows it.

```bash
for n in 1 2 3 4 5 6 7 8; do
  p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    echo "agent-$n busy (pid $p) $(git -C ~/.claude/agents/agent-$n branch --show-current 2>/dev/null)"
  fi
done
gh pr list --state open --base <BASE_BRANCH> --json number,title,headRefName,isDraft
```

Also report `QUEUE_CACHE` and `WORK_CACHE`: how many entries are waiting in each
and how old `builtAt` is, plus the count of open PRs carrying `INVALID_LABEL`.
Do not rebuild either — `status` spawns nothing and spends nothing.

## Mode: stop

1. End the repeat: kill the waiter (`TaskStop` on the backgrounded `gate.sh
   --wait`, or `pkill -f "gate.sh --wait"`) **and** stop the `/loop` heartbeat in
   the session that runs it. Both, or the loop restarts itself. The user can also
   interrupt with escape, or just say "stop the orchestrator".
2. Delete `QUEUE_CACHE` and `WORK_CACHE`. Both are caches of a moment that has
   passed, and leaving them means the next run's first tick spawns against a
   stale picture.
3. Leave the running agents alone unless the user asks. Each one still has a
   PR to open, and killing its window loses uncommitted work.
4. List the PRs the run produced so the user can read them. `gh pr list` has
   no body filter, so read the bodies and keep the ones with the 🌙 marker:
   `gh pr list --state open --base <BASE_BRANCH> --json number,title,isDraft,body`.

---

## What goes wrong

The failure modes seen on real runs — a tick that spawns nothing, `slots` stuck
at 0, a promoted PR the user re-drafts, `mergeable: UNKNOWN`, a screenshot
committed as a file, and the rest — are in
[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md). Read it when a run looks wrong.
