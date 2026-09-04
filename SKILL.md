---
name: linear-orchestrator
description: Nightly orchestrator that turns tracker tickets into reviewed PRs unattended. Runs on a 5-minute loop, spawns one agent per 2.5 GB of free RAM every tick (uncapped by default, so it reaches full capacity immediately), picks Todo tickets from Linear assigned to a preferred or fallback assignee — unassigned tickets and the Backlog column are opt-in, not the default, and spawns `cca` agents on Opus — one to write the code and open a draft PR, a second in a fresh context to review that diff and fix what the review found. Point it at your own repo in the Project settings table. Use when the user says "start the orchestrator", "run the nightly loop", "orchestrate linear", or asks for tickets to be worked through unattended overnight.
---

# linear-orchestrator — unattended nightly ticket runner

One agent writes the code and stops. A second agent, in a fresh context,
reviews that diff and fixes what the review found. Every PR opens as a draft and
stays one until it earns its way out. The loop never merges.

## Project settings

Per-user values live in `.env` beside this skill — copy `.env.example`. `gate.sh`
and every tick read it:

| `.env`                | called              | is                                         |
| --------------------- | ------------------- | ------------------------------------------ |
| `LO_REPO`             | `REPO`              | local checkout the agents clone from       |
| `LO_BASE`             | `BASE_BRANCH`       | branch to cut from and target (`dev`)      |
| `LO_TEAM`             | `TRACKER_TEAM`      | Linear team name                           |
| `LO_PREFIX`           | `TICKET_PREFIX`     | ticket id prefix, e.g. `PROJ`              |
| `LO_TIER1` `LO_TIER2` | `ASSIGNEE_TIER_1/2` | preferred / fallback assignee. Only these are taken |
| `LO_ALLOW_UNASSIGNED` | `ALLOW_UNASSIGNED`  | `1` to also take unassigned tickets (default `0`) |
| `LO_ALLOW_BACKLOG`    | `ALLOW_BACKLOG`     | `1` to fall to `Backlog` when `Todo` is empty (default `0`) |
| `LO_OWNER`            | `OWNER`             | tag identifying this instance on the forge; required when two orchestrators share one repo |
| `LO_RAM_PER_AGENT`    | `RAM_PER_AGENT_GB`  | GB per agent (default `2.5`; raise it for a stack running Docker or a local DB) |
| `LO_MAX_AGENTS`       | `MAX_AGENTS_CAP`    | ceiling on concurrent agents; `0` = unlimited (default `0`) |
| `LO_SLOT_SCAN`        | `SLOT_SCAN`         | agent slots to probe for liveness (default: what RAM allows, floor 8) |
| `LO_FEEDBACK_SINCE`   | `FEEDBACK_SINCE`    | nothing older is read as feedback          |
| `LO_FEEDBACK_LOGINS`  | `FEEDBACK_LOGINS`   | GitHub logins whose comments steer the loop; empty means every non-bot login |

Fixed: `TRACKER` Linear MCP · `FORGE` GitHub (`gh`) · `AGENT_GUIDE` your repo's
`CLAUDE.md` · `READY_STATUS` `Todo`, then `Backlog` only when `ALLOW_BACKLOG=1` ·
`CLAIMED_STATUS` `In Progress` · `INVALID_LABEL` `invalid` · `REVIEW_COMMAND`
`/review <PR#>` · `DEV_SERVER` Vite on a free port 5200–5299 · `PROD_SURFACES`
never write · `QUEUE_CACHE` / `WORK_CACHE`
`~/.claude/linear-orchestrator/<PREFIX>-{queue,work}.json` · `MAX_AGENTS` =
`floor(ram / RAM_PER_AGENT_GB)`, or `min(MAX_AGENTS_CAP, that)` when the cap > 0.

- **Every tick spawns every free slot, not one.** `slots` is
  `floor(free_ram / RAM_PER_AGENT_GB)`, bounded by `MAX_AGENTS - busy`.
- **Two orchestrators on one repo each need their own `LO_OWNER`** — the marker
  they write and match is `🌙 lo:<LO_OWNER>`, and it is the only thing that keeps
  each from adopting the other's PRs.
- **Precondition: the repo has its own `AGENT_GUIDE`.** The agent prompt below
  assumes it. Without one you get an unattended Opus agent on
  `--dangerously-skip-permissions` with almost no instructions.

## Modes

| Argument      | Mode                                        |
| ------------- | ------------------------------------------- |
| none, `start` | Start the loop — arm the blocking gate.     |
| `tick`        | One tick.                                   |
| `status`      | Report what is running. Spawn nothing.      |
| `stop`        | Stop the loop. Spawn nothing.               |

---

## Mode: start the loop

1. Confirm the working directory is `REPO` — `cca` clones `$PWD`.
2. Delete any stale `QUEUE_CACHE`.
3. Run **one tick immediately**.
4. **Arm the waiter** — Bash tool, `run_in_background: true`,
   `dangerouslyDisableSandbox: true`:

   ```
   bash "<this skill's directory>/gate.sh" --wait
   ```

   Its exit is the next tick. Then add the safety net, because a dead waiter
   takes the loop with it: invoke the `loop` skill with
   `/loop 1h /linear-orchestrator tick`. Do not detach either with `nohup`, and
   do not write ticks to a log file.
5. Tell the user the loop is live, what the first agents took, and how to stop it.

Do not gate on the clock.

---

## Mode: one tick

Five steps. Stop at the first that says stop, and report why.

### Step 1 — capacity

Run `bash "<this skill's directory>/gate.sh"` **unsandboxed** — `sysctl` and the
`~/.claude/` locks are denied inside the sandbox. Do not inline what it does. It
prints either a `NO` line or:

```
load1=… freegb=… diskgb=… busy=… slots=N
notes: …                 # a reap, a refused fetch, a Linear hiccup
world-changed: yes
REGATE: [ … ]            # promoted PRs that stopped being mergeable / went red
FEEDBACK: [ … ]          # unanswered comments on the loop's PRs
INVALID: [ … ]           # PRs the user labelled invalid
DRAFTS: [ … ]            # open loop drafts not already in an agent's hands
STACK: [ … ]             # of those, the ones based on another branch
RESTACK: [ … ]           # stack layers behind their base, with how far
TODO-CANDIDATES: ID,ID   # eligible Todo ids (only when slots>0)
```

- **On a `NO` line, end the tick** and report the reason the gate gave.
- **`linear not read` is literal** — the gate reads Linear only when a slot
  exists, so a `NO` at `slots=0` says nothing about the board. Repeat that line.
- **If the waiter woke this tick, read its output file by path.** The task
  notification names the file; it is not the block. Open it before anything else,
  and do not run `gate.sh` again.
- **`--- still nothing after 40m, re-arm ---`** — arm the next waiter, end the tick.
- **A tick that only wants to look uses `--peek`** — same probe, never writes the
  state file. A plain run while a waiter is alive swallows that waiter's next wake.
- `TODO-CANDIDATES` is pre-filtered on assignee and not-archived only. Still apply
  the 2d drop rules and dedup against open PRs.
- `agent-codemode` must be on `PATH` or at `~/.local/node/bin/agent-codemode`, or
  the gate skips Linear and says so in `notes`.

**`STACK`** — sort the layers bottom-up by their `base` and review and promote
them in that order.

**`RESTACK`** — the stack cannot merge even though every layer reads
`MERGEABLE` with green CI. Restack the **whole** stack bottom-up in one
operation, in **its own agent**, never in the user's checkout. This is the loop's
own work: dispatch it, do not ask. It is the one sanctioned exception to "no
history rewrite on a branch with an open PR", and its edges are narrow — layers
of one stack the loop opened, rebased only onto each other, when every layer is
promoted. Restack when the stack is otherwise finished, not after each fix pass.

`FEEDBACK` and `REGATE` are work at any slot count — an ack, a re-draft and a
follow-up ticket need no agent.

### Step 2 — pick the next `slots` pieces of work

Strictly ordered. Fill from the top; fall to the next kind only when the one
above is empty.

1. **Human feedback** — an unanswered comment on one of the loop's PRs, or a PR
   marked `INVALID_LABEL` (2a).
2. **De-gate** — a promoted PR that stopped being mergeable or went red (2b). A
   `RESTACK` line is a de-gate too.
3. **Finish a draft** (2c).
4. **Start a ticket** from `QUEUE_CACHE` (2d).

#### 2a — Act on what a person said

**Every comment the loop or its agents write on GitHub starts with
`<!-- 🌙 lo:<OWNER> -->`** (`<!-- 🌙 -->` when `LO_OWNER` is empty). On a Linear
ticket, a visible `🌙` instead — Linear renders HTML comments as literal text. No
exception: reviews, fix-pass replies, promotion comments, de-gate notices, acks.
An unmarked comment on a loop PR is a person talking to it.

**The loop's comments are collapsed; a person's are not.** Each goes in a
`<details>` whose summary names the contents, with a blank line under the
`<summary>` line. Four things never collapse: a `## Blocked on` notice, the
human-action line of a promotion comment, an ack, and anything a person wrote.

**Every comment gets an ack**, including ones that need no work. The reply starts
with `<!-- 🌙 ack:<id> -->`, which is how the gate knows it is answered.

Take entries oldest first. Read the body with
`gh api repos/<owner>/<repo>/issues/comments/<id> --jq .body`, or
`…/pulls/<pr>/reviews/<id> --jq .body` for an entry with `kind: "review"`, then
route on the PR state:

1. **`OPEN`** — re-draft (`gh pr ready --undo <PR#>`), ack with what you
   understood, and dispatch the rework with the comment quoted verbatim.
2. **`MERGED` / `CLOSED`** — create a ticket in `READY_STATUS` with the comment
   quoted and the PR linked; ack with the ticket id.
3. **Neither** — ack with the answer and invent no work.

"Stop", "leave it", "this is fine" — ack and do nothing. Never argue with a
person on a PR.

**A comment naming numbers is a ticket order.** The numbers are the PR body's
`## Out of scope & Suggestions` items, or a research PR's numbered options. Read
the named items out of the body, create one ticket each in `READY_STATUS` with
the item **quoted verbatim** and the PR linked, and ack with the ids. Never
renumber the section; when a PR carries both lists, say which you read.

**Before creating any ticket, check it does not exist.** Other loops write to
these PRs — the screenless loop marks its comments `<!-- ☎️ -->` and lists what
it already opened under `Already ticketed:`. Link those and create nothing. Then
search anyway:
`list_issues(team: TRACKER_TEAM, query: "<subject>", includeArchived: false)`.

**The `invalid` label**, per PR it names — find the ticket (branch name and body
carry the id), move it back to `READY_STATUS`, `gh pr ready --undo`, comment that
it was picked up, and **remove the label only once the rework is actually
spawned** (`gh pr edit <PR#> --remove-label`). The label is the durable record
that a reclaim is owed, so a PR that got no slot keeps it. Spawn the rework on
this tick ahead of any draft, claiming the ticket as in step 3 first, ordered by
priority. **Pass the user's PR comments into the spawn prompt** — they are not in
the ticket, and a rerun without them earns the same label again.

#### 2b — De-gate

For each PR on the `REGATE` line:

1. **Skip it if a live agent holds its branch** — `~/.claude/agents/agent-N.lock`
   plus `git -C ~/.claude/agents/agent-N branch --show-current`.
2. `gh pr ready --undo <PR#>`.
3. Comment why in one sentence: conflicts with `BASE_BRANCH`, or CI red.
4. Record it in `WORK_CACHE` as `needs-mergeable`.
5. **With a slot, dispatch the fix now.** Steps 1–4 need none.

Only ever touch PRs carrying the `🌙` marker. **Keep fixing, however many times
it takes.** If the same paths keep colliding, have the agent stop and name the
file and whose work it fights.

#### 2c — Finish the drafts

A draft becomes ready on five gates: a review posted on it; a fix pass over that
review with a reply comment; a screenshot if a user can see the change;
`mergeable` that is not `CONFLICTING`; and CI green on the head commit (every
non-skipped check `SUCCESS`, with a `Test (shard …)` check present to prove the
workflow ran).

**Those five are the only reasons to keep a draft.** A PR that passes them but
still needs a person — a manual test, a credential, an unconnected account — gets
**promoted**, with that item as the opening line of the promotion comment.

`WORK_CACHE` holds what each draft is missing, rebuilt on the same 30-minute
staleness rule as `QUEUE_CACHE`:

```bash
gh pr list --state open --base <BASE_BRANCH> --draft \
  --json number,title,body,files,reviews,comments,commits
```

Classify each draft. **Check `## Blocked on` first** and promote on the spot:

- **blocked** — the body carries `## Blocked on` as a heading on its own line
  (`grep -E '^## Blocked on'`, never as a substring — a PR writing *about* the
  convention would otherwise be promoted unreviewed). `gh pr ready <PR#>` now,
  whatever state the code is in, and comment with the blocker as the opening
  line. A research PR lands here by design. Record it and take no further action.
- **needs-mergeable** — `mergeable` is `CONFLICTING`, or CI on the head commit is
  failing. `UNKNOWN` is not this state; it means ask again next tick.
- **needs-split** — a reviewer read it and said it cannot be reviewed in one
  sitting, naming the seam. Nothing else puts a PR here — not a file or line count.
- **needs-review** — no review-shaped loop comment **dated after the head
  commit**. Compare `.comments[].createdAt` against `.commits[-1].committedDate`.
- **needs-fix** — a review exists, but no commit after it and no reply comment.
- **needs-screenshot** — it touches a route, a component or a non-`.server` UI
  file, and the body carries no screenshot. A screenshot is a raster image on
  GitHub's attachment host: a URL containing `user-attachments`, not ending in
  `.svg`. Do not accept `raw.githubusercontent.com` (that would pass a committed
  image) and do not test for `![` or `<img` alone (CI bots inject SVG badges).
  Test the whole body, not a heading.
- **ready** — `gh pr ready <PR#>` and drop it from the cache. This is the only
  place a PR is promoted, and it happens on evidence, never on an agent's say-so.

Order after blocked: needs-mergeable, needs-fix, needs-split, needs-review,
needs-screenshot. Oldest PR first within a kind.

#### 2d — Start a new ticket

Only when 2a, 2b and 2c are empty. `QUEUE_CACHE`:

```json
{ "builtAt": "2026-08-13T02:14:07Z",
  "tickets": [ { "id": "XXX-431", "branch": "feature/xxx-431-fix-something" } ] }
```

`Read` it and rebuild only when it is missing or `builtAt` is over 30 minutes
old. Otherwise take the first `slots` entries and read nothing from the tracker.
Fewer entries than slots is not a reason to rebuild. **An empty but fresh queue
means no eligible work — end the tick, do not double-check.** Remove entries as
you take them and write the file back **before** spawning.

**Rebuilding the queue**

```
list_issues(team: TRACKER_TEAM, state: READY_STATUS, includeArchived: false,
            fields: ["identifier","title","description","gitBranchName",
                     "priority","assignee","labels","updatedAt"])
```

`includeArchived` defaults to `true` — pass `false`, and drop any non-null
`archivedAt`. `state:` matches the status **type**, not the column name, so
filter to the exact column you meant.

Assignee tiers, strict, exhaust one before the next: `ASSIGNEE_TIER_1`, then
`ASSIGNEE_TIER_2`, then unassigned **only when `ALLOW_UNASSIGNED=1`**. Never take
a ticket assigned to anyone else.

Then drop every ticket that:

- already appears in an open PR
  (`gh pr list --state open --base <BASE_BRANCH> --json headRefName,title`);
- is only a write to a `PROD_SURFACE`;
- needs an artifact no agent has — a design file, a customer decision, a
  credential, an unconnected account.

A vague description is **fine to take**; deciding what it meant is the agent's
job. **A research ticket is work, not a skip** — the answer is the PR body, the
diff stays empty, and it ships out of draft with `## Blocked on` naming the
decision owed and a numbered list of options to answer.

Order by priority (1 Urgent → 4 Low, 0 None last), then oldest `updatedAt`, and
write the whole list with a fresh `builtAt` — **even when nothing survives**.
Only when nothing survives and `ALLOW_BACKLOG=1`, run the same pass over
`Backlog` and append it after the `Todo` entries. Do not lower the bar to find work.

### Step 3 — claim before spawning

The tracker is the claim; `QUEUE_CACHE` is a cache of candidates and never one.
Per ticket, before any spawning:

1. `get_issue(<id>)` — confirm it is still in `READY_STATUS` and still assigned
   within the tiers. If it moved, drop it and take the next entry.
2. Move it to `CLAIMED_STATUS` **and assign it to `ASSIGNEE_TIER_1`** in one
   `save_issue`, whichever tier it came from.
3. Comment on the ticket: picked up by the nightly orchestrator, at what time.

If the tracker write fails, do not spawn. If the `cca` call fails after the
status moved, put the ticket back to `READY_STATUS`.

### Step 4 — spawn

One `cca` call per piece of work, from `REPO`, unsandboxed, all in a single Bash
invocation:

```bash
cca "<the full prompt>" --dangerously-skip-permissions --non-interactive --model opus
```

All three flags are load-bearing: nobody is awake to answer a prompt;
`--non-interactive` is what returns the slot to the pool; Opus for judgment.

**Work aimed at an existing PR needs a dispatch marker, written in the same Bash
call** (2a, 2b, 2c — a fresh ticket has no PR yet):

```bash
echo "<slot>" > ~/.claude/linear-orchestrator/dispatched/<PR#>
```

`cca` prints the slot it took (`agent-1 -> …`). The gate holds the PR while that
slot's lock lives, then deletes the marker itself — no cleanup.

Two `cca` rules bite here: **there is no name argument**, and `node_modules` is a
symlink into the user's checkout, so **no agent may run `npm install`**. See
`~/.claude/skills/multiclaude/SKILL.md`.

### Step 5 — report and end

One or two lines: the resource numbers, what was taken and of which kind, the
slots, any PR promoted, what is left in each cache.

**Report what landed, not what was dispatched** — every few ticks, check the PRs
whose agents have exited and say how many actually carry the review and the fix
pass. `cca` agents never report back: never wait on one, never describe what it
produced.

**Then arm the next waiter** as the last act of the tick — exactly one, never two.

Keep the tick cheap: it runs in the user's session. Project `gh` output with
`--jq`, read no ticket descriptions on a spawning tick, and never write a
paragraph about a tick that did nothing. A tick keeps nothing in its head — the
claim is the ticket status, the work is in the caches, the agents are the lock
files — so it is always safe to interrupt.

---

## The agent prompt

**Say only what the agent cannot get for itself.** It boots in a full copy of
`REPO`, so `AGENT_GUIDE` loads on its own and it has every MCP server this
session has. It fetches the ticket itself: pass the identifier and
`gitBranchName` verbatim, never the description, title or URL. Restating a rule
it already has overrides what it correctly knew.

> Work ticket **`<TICKET_PREFIX>-###`** end to end, unattended — read it in
> Linear. You boot in a `cp -Rc` copy of the working checkout, which may be on
> another branch and carry uncommitted files, so cut from a clean base:
> `git fetch origin && git checkout -f -B <gitBranchName> origin/<BASE_BRANCH>`.
> That `-f` is the one place you discard uncommitted changes despite CLAUDE.md —
> your copy is throwaway. Nobody is awake, so never stop to ask: where CLAUDE.md
> wants confirmation, **do not do it** — no merge, no push to `dev`/`main`, no
> write to production. Production steps go in the Post-merge runbook.
>
> Blockers do not stop you either. Decide what a careful colleague would defend
> in the morning, prefer the cheapest option to reverse, and record the call in a
> `## Decisions` section — the question, the choice, why, the alternative, the
> cost to reverse.
>
> **A Decision needs two or more real options.** Following an instruction is not
> a decision, however deliberate it felt. An empty Decisions section is the
> honest one on a ticket that specified everything. If a blocker is genuinely
> undecidable — a missing credential, an unconnected account — ship what you have
> with `## Blocked on` as the **first thing in the body**, never inside a
> `<details>`; the orchestrator promotes that PR on its next tick.
>
> **A ticket that asks a question is answered in the PR body, not in code.** The
> finding with its numbers, then a **numbered list of what to do next** — each
> entry the work, its cost, what it would break — then `## Blocked on` asking the
> reader to reply with a number. The diff stays empty; do not manufacture one.
>
> **Open the draft PR before you write any code**, with one empty commit if you
> need something to push. Its body: the marker line, whatever heading lines the
> template puts first, then a collapsed `## Problem` — two or three sentences on
> what is wrong, in the reader's terms, and the ticket link. Nothing else yet.
> Then **keep the body current as you go** (`gh pr edit <PR#> --body-file`); by
> the time you stop it must satisfy the PR template and the repo's PR skills.
>
> **The body opens with the PR at a glance**, under the marker and above every
> collapsed section — three things, nothing else:
>
> 1. **One line on merge order and related PRs**, linking them: `⚠️ Merge after
>    #NNNN — it rewrites the file this deletes.` / `Related: #NNNN.` / `✅ Merges
>    alone.` Nothing else surfaces this, so it is the one line that must be right.
> 2. **At most one screenshot**, the after shot from Solution, when a user can see
>    the change. Nothing when they cannot.
> 3. **The collapsed sections, each with a summary in parentheses after its
>    title** — the titles are the table now. Same headings, same order, on every
>    PR:
>
> | section | after the title |
> | --- | --- |
> | **Problem** | 1–5 words on what is wrong |
> | **Solution** | 1–5 words on what changes |
> | **Background** | nothing |
> | **Tested by AI** | nothing |
> | **Post-merge runbook** | 1–5 words, or `nothing` |
> | **Decisions** | the count, `(N)` |
> | **Out of scope & Suggestions** | the count, `(N)` |
> | **Needs human verification** | `Nothing`, or 1–3 words naming it |
> | **Risk / rollback** | `Low` / `Moderate` / `High`, plus at most 3 words |
> | **Checklist** | nothing |
>
> So: `<details><summary><b>Problem</b> (note-taker calls name the recruiter)</summary>`.
> No table above the sections, no verdict paragraph, no row per risk — a reader
> gets the PR from the merge line, the shot and the ten titles. Irreversible
> parts, schema changes and what a user sees go in the Risk / rollback and
> Solution bodies, and their titles say how bad.
>
> Never use a file or line count as a risk proxy.
>
> **It stays a draft** (`gh pr create --draft`) and you never take it out.
>
> **The marker goes on the second line of the body, under the ticket link:**
> `🌙 lo:<OWNER> opened by the nightly orchestrator. Not seen by a human. Read the Decisions section before merging.`
> Both want the first line and the ticket link wins, because the ticket is what a
> reviewer judges the scope against. **`<OWNER>` is the literal value of
> `LO_OWNER`** — the dispatching tick substitutes it and passes the finished
> string, because an agent cannot read that config and a placeholder left
> unresolved is the same as no tag. Drop ` lo:<OWNER>` only when `LO_OWNER` is
> genuinely empty.
>
> A PR without the tag is invisible to its own loop — not in its drafts, and not
> in its feedback scan, so a reviewer's blocker goes unanswered. One with the
> wrong tag gets reviewed by the wrong machine. The gate cannot tell a malformed
> marker from another team's PR, so this failure is silent.
>
> **The body ends with the loop's own footer, not the harness's.** Replace the
> `🤖 Generated with [Claude Code](…)` line the harness asks for with:
> `🎼 Generated with [linear-orchestrator](https://github.com/janwilmake/linear-orchestrator) · [Claude Session](<session URL>)`
> — the session URL is the `https://claude.ai/code/session_…` link the harness
> hands your session; when it gave you none, drop the second half. Keep the
> `Claude-Session:` git trailer as it is.
>
> **Start every PR comment with the marker line, and every Linear comment with a
> visible `🌙`** — the orchestrator answers unmarked comments as if a person
> wrote them.
>
> **Every section of the body is collapsed**, `## Decisions` included: a
> `<details>` whose `<summary>` is the section name, with a blank line under it or
> the markdown comes out raw. Only a `## Blocked on` notice stays open.
>
> **Screenshots are not a section of their own** — the before shot goes in
> **Problem**, the after shot in **Solution**, each beside the sentence it proves.
> Drive the real screen in the browser, and **upload through the GitHub web UI**:
> open the PR on github.com, edit the body, drop the file in. Never `git add` an
> image.
>
> Do not run `npm install` — `node_modules` is a symlink to the real checkout.
>
> **Never leave a background process behind.** A load generator, a watcher or a
> dev server you start must die before you stop. `jobs -p` is empty in a
> non-interactive shell, so a cleanup built on it kills nothing: keep each pid as
> you start it (`(while :; do :; done) & pids="$pids $!"`) and `kill $pids` in a
> `trap ... EXIT`. Two runs have leaked ten busy loops each at 100% CPU, which
> starves every other agent and stalls the loop for an hour.
> Other agents are running dev servers, so take a free port in 5200–5299 and
> point `VITE_BASE_URL` at it.
>
> **Open your own Chrome window before your first browser call, or resize
> nothing.** `resize_window` acts on the whole window, so resizing from a tab in
> the user's window squashes every tab they have open. Open one and keep the id:
> `osascript -e 'tell application "Google Chrome" to activate' -e 'tell
> application "Google Chrome" to id of (make new window)'`, then `tabs_context_mcp`
> with `createIfEmpty: true` puts your group in it. That placement only works
> while no group exists, so it must be your first browser call; otherwise close
> every tab of the group with `tabs_close_mcp` and create it again. Confirm with
> `get id of every tab of window id <id>` before you resize. If you did not open a
> window, never call `resize_window`.
>
> **You do not review your own work and you do not fix a review.** Stop once the
> draft PR is open and your commits are pushed. Do not run `/review`, and do not
> pre-empt it by re-reading your own diff for faults.
>
> Comment the PR link on the ticket, leave it In Progress, and stop.
>
> **Then clean up, as the last thing you do:** close the window you opened
> (`close window id <id>`), close every tab you opened outside it with
> `tabs_close_mcp` — nobody else can, tabs are scoped to your MCP session — read
> back the `bounds` of any window you did not open and restore anything that
> changed, and stop the dev server.

### The prompts for finishing a draft (2b and 2c)

Shorter: no branching, no Decisions, no claim. Each starts with
`gh pr checkout <PR#>` and each ends with **leave it a draft** — only the
orchestrator promotes.

All of them **start every comment with `<!-- 🌙 -->`**, **collapse what they
write** in a `<details>` naming the contents (`🌙 Review — 6 findings, 2
blockers`), and **end with the same teardown as the agent prompt** — window,
tabs, bounds, dev server. The dev server is a detached `npm exec` child that
survives the session and holds 150–200 MB the capacity gate never sees.

**needs-split** — a reviewer said it cannot be reviewed in one sitting, naming
the seam. This agent does not review it; it re-cuts it.

* Give the file count and say the job is to re-cut, **not** to change what it
  does: **the combined diff of the stack must equal the original diff.**
* **Find the seams from the dependency order**, not the file tree — schema and
  migration at the bottom, then pure modules, then routes, then UI. A layer that
  cannot build and pass its own tests alone is in the wrong place.
* Use the repo's stacking tool (`gh-stack` here). **Each layer targets the layer
  below**, except the bottom one.
* Every layer is a draft, carries the marker, links the ticket.
* **Close the original PR last**, after the stack is up and verified, with a
  comment linking every layer.
* **"This is one indivisible change" is a legitimate answer** — say so with the
  reason and leave it. Do not manufacture layers.

**restack** — a finished stack that cannot merge. A git operation and nothing
else: no features, no bug fixes.

* Name every branch bottom to top with its PR number and `behind` count.
* **Rebase the layers onto each other only, not onto the trunk.**
* Force-pushing the layers is expected and is the point — say so, or an agent
  that read the other prompts will refuse.
* **Verify with numbers**: `behind_by` 0 for every layer, every PR still open and
  still out of draft.
* **Resolving a conflict**: it is a lower layer's fix-pass commit against what a
  higher layer put on top. **The lower layer's fix is the newer, reviewed
  intent** — keep it and adapt the layer above. Never drop a fix to ease a
  rebase. If a resolution would change what the stack *does*, stop, leave the
  rebase aborted, and report which two commits fought.
* Run the `AGENT_GUIDE` checks on the conflicted branch **and every branch above it**.
* It must not merge, touch the trunk, edit a PR body, or change any commit
  beyond what the conflict required.
* It reports on the top layer's PR: what it rebased, every conflict, the numbers.

**needs-review** — the main one.

* Say the PR was opened by another agent and has never been reviewed.
* **You may stop and call it unreviewable.** Read the whole diff first; if you
  cannot hold it in one sitting, post one comment naming *why* and *where the
  seam is*, and stop. That comment is what puts the PR into needs-split. Size
  alone does not decide it — four thousand lines of generated code is one
  decision, three hundred lines spanning auth, tenancy and a migration may not
  be. **You are the judge because you read it; the gate only counts.**
* Run `REVIEW_COMMAND`. **The review lands as one ordinary PR comment**
  (`gh pr comment`), not a GitHub review with line notes. Run it in the
  foreground and poll any background subagent — idling ends the session and kills
  the pending review. Confirm with `gh pr view <PR#> --json comments` before you
  fix anything, and write the comment yourself if it is not there.
* Then **one** fix pass: every blocker, plus mechanical nits inside files the PR
  already changed. Leave the rest, do not widen the diff, do not review twice.
  Re-run the `AGENT_GUIDE` checks, re-test in the browser any blocker whose proof
  was a runtime one, push one commit, and reply: what was fixed, in which commit,
  what was left and why.
* **Fix the PR body where the diff has moved past it.** Keep the marker and
  `## Decisions`, but **delete Decisions entries that record no choice**. Fix the
  shape too: every section collapsed, blank line under each `<summary>`,
  screenshots in Problem and Solution rather than a `## Screenshots` section.
* **The at-a-glance lines are yours to correct** — the author wrote them before
  the review existed. The merge-order line is the one most often wrong: check for
  another open PR on the same call site. Recount **Decisions** and **Out of scope**
  after your fix pass, and re-grade **Risk / rollback**'s word if the review
  found a blocker. Keep every title summary within its word budget.
  The body's last line is the loop footer —
  `🎼 Generated with [linear-orchestrator](https://github.com/janwilmake/linear-orchestrator) · [Claude Session](…)`
  — so replace a bare `Generated with Claude Code` line with it, keeping the
  author's session link.

**needs-fix** — a review is already there. Say where to read it
(`gh pr view <PR#> --json comments`, or
`gh api repos/<owner>/<repo>/pulls/<PR#>/comments` for older inline reviews) and
say **do not run the review again**. One fix pass, one commit, one reply.

**needs-mergeable** — the branch cannot merge, or CI is red. Say which, and that
it is the only thing to fix.

* **Merge `BASE_BRANCH` in, do not rebase** — a force-push here would throw away
  the review comments' line anchors.
* Resolve each conflict keeping **both** intents. If the two cannot both hold,
  that is a Decision to write in a PR comment, not a coin toss.
* **Change nothing else.** The diff grows only by the resolution and by what CI
  named.
* Re-run the `AGENT_GUIDE` checks, push, then comment: what conflicted, how it
  was resolved, what CI said.

A conflicted PR shows **no CI at all** rather than red CI — fix the conflict
first and let CI run afterwards.

**needs-screenshot** — the narrowest: check out the branch, start a dev server,
drive the changed screen, capture before and after, edit them into **Problem**
and **Solution**, **change no code**. A bug found on the way goes in a comment,
not the diff. **Upload through the GitHub web UI, never `git add` an image** —
the diff must not grow by a single file.

### Why one comment, and one fix pass

- **One PR comment, not a GitHub review** — an inline review leaves the PR
  blocked by a verdict from an account that never returns, and its line notes
  vanish when the fix rewrites those lines.
- **The comment before the fix** — the review is the morning's best signal, and
  fixing first means it never exists.
- **One fix pass** — self-review does not converge, and the agent holds its slot
  the whole time.
- **The reviewer is a different agent in a different context** — an author
  re-reads its diff with the intent it meant, not the intent it wrote.
- **Fixing does not earn a merge.** Author and reviewer are one model.

---

## Mode: status

Report, and change nothing.

```bash
for n in $(seq 1 "${LO_SLOT_SCAN:-8}"); do
  p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    echo "agent-$n busy (pid $p) $(git -C ~/.claude/agents/agent-$n branch --show-current 2>/dev/null)"
  fi
done
gh pr list --state open --base <BASE_BRANCH> --json number,title,headRefName,isDraft
```

Also list the claimed tickets
(`list_issues(team: TRACKER_TEAM, state: CLAIMED_STATUS)`) paired with their PRs —
a claimed ticket with no open PR and no live agent is stranded, and this is the
only place that shows it. Report both caches' entry counts and `builtAt` age, and
the count of open PRs carrying `INVALID_LABEL`. Rebuild nothing.

## Mode: stop

1. Kill the waiter (`TaskStop`, or `pkill -f "gate.sh --wait"`) **and** stop the
   `/loop` heartbeat. Both, or the loop restarts itself.
2. Delete `QUEUE_CACHE` and `WORK_CACHE`.
3. Leave the running agents alone unless the user asks — each still has a PR to
   open.
4. List what the run produced. `gh pr list` has no body filter, so read the
   bodies and keep the ones with the marker:
   `gh pr list --state open --base <BASE_BRANCH> --json number,title,isDraft,body`.

---

## What goes wrong

Failure modes seen on real runs are in [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).
