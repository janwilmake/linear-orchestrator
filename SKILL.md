---
name: orchestrate-linear
description: Nightly orchestrator that turns tracker tickets into reviewed PRs unattended. Runs on a 5-minute loop, spawns one agent per 2.5 GB of free RAM, picks Todo tickets from Linear (a preferred assignee or unassigned first, a fallback assignee second), and spawns `cca` agents on Opus that open the PR, review it, and fix the blockers their own review found. Point it at your own repo in the Project settings table. Use when the user says "start the orchestrator", "run the nightly loop", "orchestrate linear", or asks for tickets to be worked through unattended overnight.
---

# orchestrate-linear — unattended nightly ticket runner

Turns ready tickets into reviewed pull requests while nobody watches. Each PR
arrives with the agent's own review posted on it, and the blockers from that
review already fixed.

**Every PR opens as a draft, and stays one until it has earned its way out** —
a review, a fix pass over that review, and a screenshot if a user can see the
change. Draft is therefore the honest signal: what is ready in the morning is
what is not a draft. The loop also finishes drafts before it starts anything new,
and picks up any PR the user marks `invalid` by putting its ticket back in the
ready column for another pass.

It still never merges anything. A review by the agent that wrote the code is the
weakest evidence available — same model in both roles, same assumptions. The
morning job is to read the PRs, not to fix a broken base branch.

## Project settings

Everything project-specific lives here. The rest of the file refers to these
names, so pointing the skill at another repo means editing this table and
nothing else.

| Setting             | Value                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------- |
| `REPO`              | `/path/to/your/repo`                                                                    |
| `AGENT_GUIDE`       | `CLAUDE.md` — §2.6 lists what needs confirmation, §2.8 the ticket status rule            |
| `TRACKER`           | Linear MCP                                                                              |
| `TRACKER_TEAM`      | `Hyre Ops`                                                                              |
| `TICKET_PREFIX`     | `HYR2`                                                                                  |
| `READY_STATUS`      | `Todo`, then `Backlog` once no `Todo` ticket is eligible                                 |
| `CLAIMED_STATUS`    | `In Progress`                                                                           |
| `ASSIGNEE_TIER_1`   | Preferred assignee (`you@example.com`), or unassigned                                   |
| `ASSIGNEE_TIER_2`   | Fallback assignee (`colleague@example.com`)                                             |
| `BASE_BRANCH`       | `dev`                                                                                   |
| `FORGE`             | GitHub, via `gh`                                                                        |
| `DEV_SERVER`        | Vite — free port in 5200–5299, with `VITE_BASE_URL` pointed at it                       |
| `RAM_PER_AGENT_GB`  | `2.5` — one `claude` + one Vite server + one Chrome. On 8 GB that caps `MAX_AGENTS` at 3 |
| `PROD_SURFACES`     | Railway prod variables and service config, prod data, third-party dashboards on prod    |
| `REVIEW_COMMAND`    | `/review <PR#>`                                                                         |
| `INVALID_LABEL`     | `invalid` — the user puts this on a PR whose AI review-and-fix pass did not satisfy them |
| `QUEUE_CACHE`       | `~/.claude/orchestrate-linear/HYR2-queue.json` — one file per `TICKET_PREFIX`            |
| `WORK_CACHE`        | `~/.claude/orchestrate-linear/HYR2-work.json` — leftover work on already-open draft PRs  |

**Before porting this to another repo, check the precondition:** that repo must
have its own agent guide. The prompt in this skill is four short paragraphs
*because* `AGENT_GUIDE` supplies branching, local checks, the PR template, e2e
testing and the security rules. Point it at a repo with no such file and you
get an unattended Opus agent running with `--dangerously-skip-permissions` and
almost no instructions. Write the guide first.

`RAM_PER_AGENT_GB` is calibrated for a Vite server plus Chrome. A stack that
runs Docker or a local database needs a bigger number — the capacity gate
cannot detect this and will happily over-spawn.

## Modes

Pick by the argument you were called with.

| Argument      | Mode                                             |
| ------------- | ------------------------------------------------ |
| none, `start` | **Start the loop** — set up the 5-minute repeat. |
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
4. Then start the repeat:

   ```
   /loop 5m /orchestrate-linear tick
   ```

5. Tell the user the loop is live, which tickets the first agents took, and how
   to stop it.

Do not gate on the clock. The user starts the loop when they stop working and
stops it in the morning; a hardcoded night window would break every daytime
test run.

**Why 5 minutes and not 15.** An agent finishes somewhere between 10 minutes
and an hour, and a slot that frees up right after a tick is a slot the machine
idles through until the next one. At 15 minutes that wasted about 7 minutes per
completed agent and, worse, meant the loop crawled back up to full concurrency
one agent at a time. Five minutes is affordable only because of the queue cache
below: a tick with no free slot costs one `bash` call and one line of output,
and a tick that spawns reads no ticket descriptions at all.

---

## Mode: one tick

Five steps. Stop at the first one that says stop, and report why.

### Step 1 — how many agents does the machine have room for?

**This is the first thing every tick does, before the tracker, before the queue,
before anything else.** Most ticks end here, and a tick that ends here must cost
one `bash` call and one line of output — that is what makes a 5-minute loop
cheap enough to run all night. The reaper below shares that one call, and adds
a line only on the ticks where it actually killed something.

Run this probe **outside the Bash sandbox** (`dangerouslyDisableSandbox: true`).
`sysctl` and the lock files under `~/.claude/` are both denied inside it — the
sandboxed call fails with `Operation not permitted`, so go straight to the
unsandboxed one.

```bash
# Refresh BASE_BRANCH at most once an hour. cca clones $PWD, so a stale local
# dev is silently inherited by every agent spawned from it.
stamp=~/.claude/orchestrate-linear/last-fetch
if [ ! -f "$stamp" ] || [ $(( $(date +%s) - $(stat -f %m "$stamp") )) -gt 3600 ]; then
  if [ -z "$(git -C <REPO> status --porcelain)" ] \
     && [ "$(git -C <REPO> branch --show-current)" = "<BASE_BRANCH>" ]; then
    before=$(git -C <REPO> rev-parse --short HEAD)
    git -C <REPO> pull --ff-only --quiet origin <BASE_BRANCH> 2>/dev/null \
      && after=$(git -C <REPO> rev-parse --short HEAD) \
      && [ "$before" != "$after" ] && echo "dev $before -> $after"
    touch "$stamp"
  else
    echo "dev NOT refreshed: repo is dirty or not on <BASE_BRANCH>"
  fi
fi

# Reap first: a slot with no live lock must own no processes.
for n in 1 2 3 4 5 6 7 8; do
  p=$(cat ~/.claude/agents/agent-$n.lock 2>/dev/null)
  if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
    pids=$(pgrep -f "/.claude/agents/agent-$n/" 2>/dev/null)
    [ -n "$pids" ] && { echo "reaped agent-$n: $(echo $pids | tr '\n' ' ')"; kill $pids 2>/dev/null; }
  fi
done
sleep 2
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
echo "cores=$cores ramgb=$ramgb load1=$load freegb=$freegb diskgb=$diskgb busy=$busy"
```

**Why the fetch is here and not in the agent prompt.** `cca` clones `$PWD` at
spawn time, so whatever commit `REPO` is sitting on becomes the base of the
agent's branch. A `REPO` left on last night's `dev` therefore produces PRs that
branch from stale code — they merge cleanly, pass their own tests, and quietly
revert or conflict with whatever landed in between. The agent cannot detect
this: from inside its copy, its `dev` looks like `dev`. The only place to fix it
is before the clone.

**Hourly, not every tick.** A fetch costs a network round trip and the base
branch does not move every five minutes; twelve an hour is eleven wasted. The
stamp file is what keeps it hourly, and `--ff-only` is what keeps it safe — if
someone has committed locally on `dev`, the pull fails rather than merging, and
the tick carries on with the old base.

**It refuses rather than forces.** A dirty `REPO`, or one parked on another
branch, means somebody is working in it, and a checkout or stash under their
hands is far worse than an hour-old base. It says so in one line and moves on;
that line is the cue to sort the working copy out by hand.

**Reap before measuring, or the gate reads a lie.** `--non-interactive` ends
the `claude` session, but `DEV_SERVER` was started as a detached `npm exec`
child and outlives it. Every completed agent therefore leaks its dev server —
measured at 150–200 MB each on this stack — and the leak is invisible to the
lock files, so `busy` reads the slot as free while the memory is still gone.
Six agents into a night that is a gigabyte of `freegb` the gate never sees,
which is the difference between spawning three agents at once and spawning one
per tick for hours.

The match is on the agent's own directory path, so it can only ever kill
processes belonging to that slot, and it only runs against a slot whose lock is
missing or dead. Note the second failure it catches: `cca` re-clones over
`agent-N`, so a leaked server keeps serving the *previous* occupant's checkout
on its port. An agent that opens that port is testing another ticket's code and
has no way to tell.

Read free memory from `vm_stat`, not from `memory_pressure`. The
`free percentage` that `memory_pressure` prints counts pages the kernel has
already compressed, so it overstates the headroom — it reads 53% on this
machine at moments when `vm_stat` shows 1.3 GB actually available. A gate on a
number that cannot be spent is not a gate.

**The slot count is free memory divided by the cost of an agent:**

```
slots = max( 0, min( MAX_AGENTS - busy, floor(freegb / RAM_PER_AGENT_GB) ) )
MAX_AGENTS = min(4, floor(ramgb / RAM_PER_AGENT_GB))
```

Both quotients floor, and `slots` clamps at 0. `RAM_PER_AGENT_GB` need not divide
`ramgb` evenly — 8 GB at 2.5 each is `floor(3.2)` = 3, not 3.2 — and `busy` can
exceed `MAX_AGENTS` after the setting is lowered mid-run, which would otherwise
make `slots` negative.

One agent per `RAM_PER_AGENT_GB` of *freeable* memory — 6 GB free at 2 GB each
is 3 agents, and this tick may spawn all three at once. `freegb` already counts
the memory of every agent currently running, so the quotient is how many *more*
fit; no settle delay or re-probe between spawns is needed, and the next tick
re-measures 5 minutes later anyway.

This is why the rule is a quotient and not a boolean. A gate that only asked
"is there room for one?" answered yes at 6 GB free and at 2.1 GB free alike, so
the loop added one agent per tick and took three ticks to reach a concurrency
the machine could have held from the start.

`MAX_AGENTS` is the ceiling on top of that: past 4 the machine thrashes no
matter what `vm_stat` claims, and `busy` is read from 8 lock files, so 8 is a
hard wall regardless.

Two conditions gate the whole tick — if either fails, `slots = 0`:

- `load1 <= cores * 0.7`
- `diskgb >= 10` — each clone costs about 100 MB, but a full disk corrupts
  every agent at once, not just the new one. This machine normally sits near
  19 GB free, so a stricter number would block every tick.

**If `slots` is 0, end the tick right here.** One line: the numbers, and which
one was zero or blocking. Do not read the tracker, do not touch `QUEUE_CACHE`,
do not explain. A skipped tick is the normal case and the next one is 5 minutes
away.

### Step 2 — pick the next `slots` pieces of work

Three kinds of work compete for a slot, and they are strictly ordered. **Fill
slots from the top, and only fall to the next kind when the one above it is
empty:**

1. **Reclaim** — a PR the user marked `INVALID_LABEL`. Below.
2. **Finish a draft** — an open draft PR with leftover work: no review, no fix
   pass after its review, or a user-visible change with no screenshot. Below.
3. **Start a ticket** — a fresh ticket from `READY_STATUS`. The original path,
   from `QUEUE_CACHE`.

The order is the whole point. **An open PR is worth more than a new one**: it is
already most of the way to mergeable, a human is waiting on it, and every hour it
sits unreviewed is an hour the branch drifts from `BASE_BRANCH`. Starting a
sixteenth ticket while fifteen drafts sit unreviewed is how a night ends with
forty PRs and nothing a human can read. Reclaim outranks both because it is the
only kind carrying *human* feedback, which is worth more than anything the loop
generates on its own.

#### 2a — Reclaim the PRs the user rejected

```bash
gh pr list --state open --base <BASE_BRANCH> --label <INVALID_LABEL> \
  --json number,headRefName,title
```

`INVALID_LABEL` means the user read the PR, read the AI review and the fix pass
on it, and was not satisfied. That is the highest-value signal this loop ever
receives — it is the only point where a human tells it that its own judgment was
wrong. For each one, in this order:

1. Find the ticket. The branch name carries the id (`feature/hyr2-431-…`), and
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
to be picked up by 2c later, because 2b sits between here and there and a backlog
of drafts would park human feedback behind thirty machine-generated PRs. Claim
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

#### 2b — Finish the drafts

Every PR this loop opens starts as a draft (step 4) and only becomes ready when
it has all three of:

- a review posted on it,
- a fix pass over that review, with a reply comment saying what was fixed,
- a screenshot, if it changes anything a user can see.

`WORK_CACHE` holds the drafts that are missing one of those, what each is
missing, and in what order to take them. Rebuild it on the same 30-minute
staleness rule as `QUEUE_CACHE`:

```bash
gh pr list --state open --base <BASE_BRANCH> --draft \
  --json number,title,body,files,reviews,comments,commits
```

For each draft, decide what it still needs:

- **needs-review** — no review and no review-shaped comment from the loop.
- **needs-fix** — a review exists, but no commit after it and no reply comment.
- **needs-screenshot** — it touches a user-visible file and the body carries no
  screenshot. On this repo a user-visible file means `app/routes/**`,
  `app/components/**`, or a non-`.server` `.tsx` under `app/`. That half is
  deliberately generous: it catches PRs whose UI files are incidental, and a
  false positive costs one agent, while a false negative ships an unreviewable
  UI change.

  **A screenshot means a raster image uploaded to GitHub's attachment host** —
  a URL containing `user-attachments`, not ending in `.svg`. Do not accept
  `raw.githubusercontent.com`: that serves files **out of the repository**, so
  matching it would pass a screenshot somebody committed, which is the one
  outcome this must not reward. Do not test for `![` or `<img` on their own. CI bots inject `<img>` badges into PR
  bodies — this repo's `blacksmith.sh` "View with codesmith" and "Autofix"
  badges are two `<img>` tags of SVG on a third-party host — and a bare
  `<img>` test reads those as proof the author screenshotted the feature. Three
  PRs were promoted to ready on exactly that mistake, one of which the user then
  had to re-draft by hand. `.svg` is the tell: screenshots are PNG or JPEG,
  badges are SVG.

  A `## Screenshots` heading is good practice and the agent prompts ask for it,
  but do not make it the test — an author who pastes an image without the
  heading has still done the thing, and the heading with nothing under it is a
  lie the test would believe.
- **ready** — none of the above. Take it out of draft with `gh pr ready <PR#>`
  and drop it from the cache. This is the only place a PR becomes ready, and it
  happens on evidence, never on an agent's say-so.

Order the rest: needs-fix first (a posted review with no fix is the most
misleading state a PR can be in — it looks checked and is not), then
needs-review, then needs-screenshot. Within a kind, oldest PR first.

#### 2c — Start a new ticket

Only when 2a and 2b are both empty. Judging eligibility means reading every open
ticket's description, and that is by far the most expensive thing a tick can do.
So it happens once and the verdict is cached: `QUEUE_CACHE` holds the tickets
that survived, in the order they should be taken, carrying only what a spawn
needs.

```json
{
  "builtAt": "2026-08-13T02:14:07Z",
  "tickets": [
    { "id": "HYR2-431", "branch": "jan/hyr2-431-fix-invite-expiry" }
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
list_issues(team: TRACKER_TEAM, state: READY_STATUS,
            fields: ["identifier","title","description","gitBranchName",
                     "priority","assignee","labels","updatedAt"])
```

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
- It is a research or discussion ticket with no code outcome.

Skipping is not the same as blocking. A ticket with a vague description is
**fine to take** — deciding what it meant is the agent's job (see Decisions
below). Only skip when no amount of good judgment produces a diff.

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

So the whole prompt is the ticket id, the branch name, and the six things that
are true only here:

> Work ticket **`<TICKET_PREFIX>-###`** end to end, unattended — read it in
> Linear, and branch as `<gitBranchName>`. Nobody is awake, so never stop to
> ask. Where CLAUDE.md wants confirmation, that means **do not do it**: no
> merge, no push to `dev`/`main`, no write to production. Production steps go
> in the Post-merge runbook.
>
> Blockers do not stop you either. Decide what a careful colleague would defend
> in the morning, prefer the cheapest option to reverse, and record every such
> call in a `## Decisions` section in the PR body — the question, what you
> chose, why, the alternative, and the cost to reverse. On a ticket with gaps,
> an empty Decisions section is wrong. If a blocker is genuinely undecidable —
> a missing credential, an account nobody connected — ship what you have as a
> **draft** PR with `## Blocked on` at the top.
>
> **Open the PR as a draft** (`gh pr create --draft`), and leave it a draft. The
> orchestrator takes it out of draft later, once it has a review, a fix pass and
> a screenshot. Start the PR body with:
> `🌙 opened by the nightly orchestrator. Not seen by a human. Read the Decisions section before merging.`
>
> If the change is visible to a user, put before/after screenshots in the body
> under `## Screenshots`. Drive the real screen in the browser to get them, and
> **upload them through the GitHub web UI** — open the PR on github.com, edit
> the body, drop the file into the editor so GitHub hosts it. Never `git add` an
> image: a screenshot is evidence about the diff, not part of it.
>
> Do not run `npm install` — `node_modules` is a symlink to the real checkout.
> Other agents are running dev servers, so take a free port in 5200–5299 and
> point `VITE_BASE_URL` at it.
>
> Then run `/review <your PR number>`. **The review must land as one ordinary PR
> comment** — `gh pr comment <PR#> --body …` — not as a GitHub review with
> comments attached to lines in the diff. Run it in the foreground: if it
> dispatches a background subagent, poll it rather than idling, because an idle
> wait ends this session and kills the pending review. Then confirm with
> `gh pr view <PR#> --json comments` that the comment is really there, and write
> it yourself if it is not. Do not start fixing until you have seen it.
>
> After that comment is posted, make **one** fix pass over what it found: every
> blocker, plus the nits that are mechanical and sit inside files you already
> changed. Leave the rest. Do not widen the diff, and do not review a second
> time — one pass, then stop fixing. Re-run the CLAUDE.md §4 local checks, and
> re-test in the browser any blocker whose proof was a runtime one. Push the
> fixes as one commit of their own, then reply on the PR: what you fixed, in
> which commit, and what you left with the reason. A PR with nothing left to fix
> still does not get merged, and does not get taken out of draft by you.
>
> Finally comment the PR link on the ticket, leave it In Progress, and stop.

Write the prompt with the settings resolved, as above — the agent has no copy
of this table. Pass `gitBranchName` verbatim from the tracker rather than
inventing a branch name: it is what makes the tracker link the PR back to the
ticket by itself.

Keep all seven paragraphs. Each covers something no file in the copy says: the
no-confirmation rule, Decisions, the marker, the two `cca` footguns, the review
call, the fix pass, and the closing sequence. Everything else the agent already
has.

### The three prompts for finishing a draft (2b)

Shorter than the ticket prompt: no branching, no Decisions section, no ticket
claim. The PR exists. Each starts with `gh pr checkout <PR#>`, and each ends
with **leave it a draft** — only the orchestrator promotes, in 2b.

**needs-review** — the whole ticket prompt's review paragraph and fix paragraph,
nothing else. Say the PR was opened earlier and never got its review, so it must
be treated as unreviewed. Include the single-comment rule and the
do-not-idle-on-the-subagent rule verbatim: those two sentences are the ones that
were failing.

**needs-fix** — a review is already on the PR. Tell the agent where to read it
(`gh pr view <PR#> --json comments`, or
`gh api repos/<owner>/<repo>/pulls/<PR#>/comments` for older PRs whose review
landed inline) and say **do not run the review again** — a second review on the
same diff produces a thinner set of findings and buries the first. One fix pass,
one commit, one reply comment.

**needs-screenshot** — the narrowest one, and it must say so: check out the
branch, start a dev server, drive the changed screen, capture before and after,
edit them into the body under `## Screenshots`, **change no code**. An agent that
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

### Why the review is one comment and not an inline review

`/review` will happily post as a GitHub *review* with comments pinned to lines
in the diff. Do not let it. Three reasons, in the order they bite:

- **A pending review can leave the PR blocked.** A review left in a non-approved
  state sits on the PR as an unresolved verdict from an account that is not
  coming back to resolve it, and on a protected branch that can hold up a merge
  a human has already approved.
- **Inline comments vanish on the next push.** The fix pass rewrites the very
  lines the review is attached to, so GitHub marks them outdated and folds them
  away. The record of what was wrong disappears exactly when someone wants to
  check whether it was fixed.
- **It is unreadable as evidence.** The morning job is to read one comment and
  decide whether the PR was checked. Fifteen collapsed line notes scattered
  through a diff is not that, and it is why a run can look reviewed while its
  `comments` count is zero.

One comment, top to bottom, with file and line references written as text.

### Why the fix pass runs after the comment, and only once

**The review comment is the morning's best signal** — the agent naming the
faults in its own work. Move the fix pass ahead of it and that record never
exists: the reader gets a clean-looking PR and no evidence that anything was
checked. So the order is post, then fix, then say what you fixed. The reply
comment keeps the trail readable end to end.

**One pass, because self-review does not converge.** An agent that reviews its
own fixes finds a fresh set of blockers every round, each one thinner than the
last, and the loop runs until the night ends. One pass also bounds the cost: the
agent holds its slot until the window closes, and at a real `MAX_AGENTS` of 2 on
this machine, every extra minute is a ticket the night does not reach.

**Fixing does not earn a merge.** The author and the reviewer are one model here,
so "no blockers left" carries no independent weight. One bad merge into
`BASE_BRANCH` at 02:00 also lands under every agent that spawns after it, which
turns one broken PR into a morning of bisecting. To make merges defensible, the
review has to come from an agent that did not write the code — a second `cca`
agent on the open PR, on a later tick. That is a different design; this file does
not do it.

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

1. End the repeat: `CronList` for an entry that runs this skill, then
   `CronDelete` it. If the loop is running in an interactive session instead,
   tell that session to stop looping.
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

- **A tick spawns nothing for hours.** Usually correct — the queue is empty of
  eligible tickets, or `MAX_AGENTS` are already busy. Check `status` before
  assuming it broke.
- **`slots` is 0 every tick, and no agent ever starts.** Measured on an 8 GB
  machine **with two agents already running** — the state that decides whether a
  third may start — `freegb` sat between 1.3 and 2.5 GB across ten samples,
  three of them under 2 GB. `floor(freegb / 2)` is 0 or 1 there, so the third
  slot is a coin toss and the cap of 4 is never reached. That is the rule
  working, not failing. To get real concurrency, add RAM — dividing by a
  smaller number does not create memory that is not there, it only lets the
  machine swap. **But check the reaper's output first:** those samples were
  taken before step 1 reaped leaked dev servers, and some of that missing
  memory was servers nobody was using. A tick that prints several `reaped`
  lines was measuring a machine fuller than it really was.
- **A dev server answering on a port no live agent claims.** A leak the reaper
  missed, most likely because the process no longer matches its slot's
  directory path. `lsof -nP -iTCP:5200-5299 -sTCP:LISTEN` names the owners;
  anything whose parent `claude` is gone is dead weight, and worse, it is
  serving a checkout `cca` has since replaced.
- **A ticket in `QUEUE_CACHE` that a human already took.** Expected: the queue
  is up to 30 minutes stale by design. Step 3's `get_issue` check catches it and
  moves on to the next entry. If tickets are being reassigned faster than that,
  shorten the 30 minutes rather than removing the check.
- **Two agents on one ticket.** The queue entry was not removed before spawning,
  or a rebuild ran between the claim and the spawn. Both are step 3 failing, not
  the cache: the tracker status is the claim, and it must move before `cca` is
  called.
- **An agent still runs long after its PR opened.** The fix pass turned into a
  review loop. Read the PR: more than one fix commit, or a second review comment,
  means the one-pass rule did not hold. Close the window once the work is pushed,
  and the ticket keeps its PR.
- **All 8 slots busy.** Agents keep their slot when they leave uncommitted work
  or unpushed commits. Read `git -C ~/.claude/agents/agent-N status` before
  closing a window — that is the run's output sitting there.
- **A ticket stuck in `CLAIMED_STATUS` with no PR.** The status moved but the
  agent never got there — a failed spawn, or a window someone closed. Nothing
  recovers it automatically. Move it back to `READY_STATUS` and the next tick
  takes it. Pairing claimed tickets against open PRs is how `status` finds
  these.
- **The machine swaps right after a tick spawned two or three at once.**
  `RAM_PER_AGENT_GB` is too low for this stack — a Docker or database service
  costs far more than a Vite server. Raise it in the settings table; the probe
  cannot see it. Batch spawning makes this fail louder than it used to: the old
  one-per-tick pace hid an underestimate behind 15 minutes of settling, and
  dividing by the wrong number now buys three agents' worth of the mistake in
  one go.
- **The same PR is reclaimed every tick.** The `INVALID_LABEL` was not removed
  in 2a. All four writes have to happen — ticket back to `READY_STATUS`, PR back
  to draft, label off, comment posted — and the label is the one that makes the
  work stop repeating.
- **A PR sits in `WORK_CACHE` forever, dispatched every few ticks and never
  finishing.** Something about it defeats the agent — a screenshot of a screen
  that needs a live integration, a review that keeps dying. Read the PR after the
  third attempt rather than spending a fourth. `WORK_CACHE` should record an
  attempt count for exactly this.
- **Drafts pile up and no ticket is ever started.** Working as designed: 2b
  outranks 2c, so a backlog of unfinished drafts stops new work until it clears.
  If that is the wrong call for a particular night, drain `WORK_CACHE` by hand
  rather than reordering the steps — the ordering is what keeps the PR list
  readable.
- **A screenshot committed as a file.** The PR's diff grows by a `.png` and the
  body links `raw.githubusercontent.com`. The agent took the shortcut of
  `git add` instead of uploading through the GitHub UI, and a detector that
  accepts `githubusercontent` calls that a pass. Check with
  `git diff --name-only --diff-filter=A origin/<BASE_BRANCH>...<branch> | grep -Ei '\.(png|jpe?g|gif|webp)$'`
  across the run's branches; a screenshot task must add **no** files.
- **The user re-drafts a PR the loop promoted.** The promotion test believed
  something it should not have. Read what the test matched on before changing
  anything — the first time this happened it was CI badge `<img>` tags counted
  as screenshots, and the fix was to require a GitHub-hosted non-`.svg` image.
  Then re-run the corrected test over **every** currently-promoted PR, not just
  the one the user caught: a bad test promotes in batches, and the user only
  sees the one they opened.
- **`dev NOT refreshed` on every tick.** Somebody left `REPO` dirty or on
  another branch, so the hourly fetch keeps refusing. Every agent spawned
  meanwhile branches from whatever commit `REPO` is parked on. Clean the working
  copy — the loop will not do it for you, on purpose.
- **A PR that merges clean but reverts something.** Its branch point predates
  the change it undoes. Check when `REPO` last fast-forwarded against when the
  branch was cut; an agent cannot see this from inside its own clone.
- **Chrome tabs pile up.** Tabs are scoped per MCP session, so no agent can
  clear another's. After a night's run:
  `osascript -e 'tell application "Google Chrome" to get URL of every tab of every window'`
- **macOS only.** `cca` needs `open -a Terminal` and APFS `cp -Rc`.
