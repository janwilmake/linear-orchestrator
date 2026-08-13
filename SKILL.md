---
name: orchestrate-linear
description: Nightly orchestrator that turns tracker tickets into reviewed PRs unattended. Runs on a 15-minute loop, checks free CPU/RAM, picks a Todo ticket from Linear (a preferred assignee or unassigned first, a fallback assignee second), and spawns a `cca` agent on Opus that opens and reviews the PR. Point it at your own repo in the Project settings table. Use when the user says "start the orchestrator", "run the nightly loop", "orchestrate linear", or asks for tickets to be worked through unattended overnight.
---

# orchestrate-linear — unattended nightly ticket runner

Turns ready tickets into reviewed pull requests while nobody watches. It never
merges anything. The morning job is to read the PRs, not to fix a broken base
branch.

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
| `READY_STATUS`      | `Todo`                                                                                  |
| `CLAIMED_STATUS`    | `In Progress`                                                                           |
| `ASSIGNEE_TIER_1`   | Preferred assignee (`you@example.com`), or unassigned                                   |
| `ASSIGNEE_TIER_2`   | Fallback assignee (`colleague@example.com`)                                             |
| `BASE_BRANCH`       | `dev`                                                                                   |
| `FORGE`             | GitHub, via `gh`                                                                        |
| `DEV_SERVER`        | Vite — free port in 5200–5299, with `VITE_BASE_URL` pointed at it                       |
| `RAM_PER_AGENT_GB`  | `2` — one `claude` + one Vite server + one Chrome                                       |
| `PROD_SURFACES`     | Railway prod variables and service config, prod data, third-party dashboards on prod    |
| `REVIEW_COMMAND`    | `/review <PR#>`                                                                         |

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

| Argument      | Mode                                              |
| ------------- | ------------------------------------------------- |
| none, `start` | **Start the loop** — set up the 15-minute repeat. |
| `tick`        | **One tick** — do the work described below.       |
| `status`      | Report what is running. Spawn nothing.            |
| `stop`        | Stop the loop. Spawn nothing.                     |

---

## Mode: start the loop

1. Confirm the working directory is `REPO`. `cca` clones `$PWD`, so a wrong
   directory clones the wrong repo. If it is wrong, `cd` there first.
2. Run **one tick immediately**, so the user sees the first agent start rather
   than waiting 15 minutes for proof that it works.
3. Then start the repeat:

   ```
   /loop 15m /orchestrate-linear tick
   ```

4. Tell the user the loop is live, which ticket the first agent took, and how
   to stop it.

Do not gate on the clock. The user starts the loop when they stop working and
stops it in the morning; a hardcoded night window would break every daytime
test run.

---

## Mode: one tick

Five steps. Stop at the first one that says stop, and report why.

### Step 1 — is there room for another agent?

Run this probe **outside the Bash sandbox** (`dangerouslyDisableSandbox: true`).
`sysctl` and the lock files under `~/.claude/` are both denied inside it — the
sandboxed call fails with `Operation not permitted`, so go straight to the
unsandboxed one.

```bash
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

Read free memory from `vm_stat`, not from `memory_pressure`. The
`free percentage` that `memory_pressure` prints counts pages the kernel has
already compressed, so it overstates the headroom — it reads 53% on this
machine at moments when `vm_stat` shows 1.3 GB actually available. A gate on a
number that cannot be spent is not a gate.

**Cap: `MAX_AGENTS = min(4, ramgb / RAM_PER_AGENT_GB)`.** On an 8 GB machine at
2 GB per agent that is **4 concurrent agents**, and pushing past it swaps the
whole machine instead of finishing sooner.

Spawn only while **all** of these hold:

- `busy < MAX_AGENTS`
- `freegb >= RAM_PER_AGENT_GB` — one agent's worth of room, in real GB. An
  absolute number, because the cost of an agent is absolute: 40% of 8 GB and
  40% of 64 GB are the same gate on paper and a different one in practice.
- `load1 <= cores * 0.7`
- `diskgb >= 10` — each clone costs about 100 MB, but a full disk corrupts
  every agent at once, not just the new one. This machine normally sits near
  19 GB free, so a stricter number would block every tick.

If any check fails, spawn nothing. Say which number blocked it and end the
tick. A skipped tick is normal and costs nothing; the next one is 15 minutes
away.

Otherwise `slots = MAX_AGENTS - busy`. That is how many tickets this tick may
take — usually one.

### Step 2 — pick a ticket

Read the ready column from `TRACKER`:

```
list_issues(team: TRACKER_TEAM, state: READY_STATUS,
            fields: ["identifier","title","description","gitBranchName",
                     "priority","assignee","labels","updatedAt"])
```

You need the title and description to judge eligibility below. The agent needs
neither — it reads the ticket itself. Only the identifier and `gitBranchName`
reach the prompt.

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
`updatedAt` first. Take the top `slots` of them.

If nothing survives, end the tick and say so plainly. Do not lower the bar to
find work.

### Step 3 — claim it before spawning

Two agents on one ticket is the expensive failure. Claim first, spawn second.

**The tracker is the claim.** There is no second ledger to keep in sync — the
ticket status is the record, it is the thing a human reads at 08:00, and a
local file that disagrees with it would block a ticket silently and forever.

1. Move the ticket to `CLAIMED_STATUS` (`save_issue`). This is also
   `AGENT_GUIDE` §2.8, and it is what hides the ticket from the next tick,
   which reads only the ready column.
2. Comment on the ticket: picked up by the nightly orchestrator, at what time.

If the tracker write fails, do not spawn. An unclaimed ticket handed to an
agent gets handed out again 15 minutes later.

If the `cca` call fails after the status moved, **put the ticket back to
`READY_STATUS`** before ending the tick. Otherwise it sits claimed with no
agent and no PR, and neither the loop nor a human picks it up again.

### Step 4 — spawn the agent

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

State: the resource numbers, the ticket taken, the agent slot, and that its
window is open. Then stop.

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

So the whole prompt is the ticket id, the branch name, and the four things that
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
> Start the PR body with:
> `🌙 opened by the nightly orchestrator. Not seen by a human. Read the Decisions section before merging.`
>
> Do not run `npm install` — `node_modules` is a symlink to the real checkout.
> Other agents are running dev servers, so take a free port in 5200–5299 and
> point `VITE_BASE_URL` at it.
>
> Then run `/review <your PR number>`, comment the PR link on the ticket, leave
> it In Progress, and stop.

Write the prompt with the settings resolved, as above — the agent has no copy
of this table. Pass `gitBranchName` verbatim from the tracker rather than
inventing a branch name: it is what makes the tracker link the PR back to the
ticket by itself.

Keep all five paragraphs. Each covers something no file in the copy says: the
no-confirmation rule, Decisions, the marker, the two `cca` footguns, and the
closing sequence. Everything else the agent already has.

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

## Mode: stop

1. End the repeat: `CronList` for an entry that runs this skill, then
   `CronDelete` it. If the loop is running in an interactive session instead,
   tell that session to stop looping.
2. Leave the running agents alone unless the user asks. Each one still has a
   PR to open, and killing its window loses uncommitted work.
3. List the PRs the run produced so the user can read them. `gh pr list` has
   no body filter, so read the bodies and keep the ones with the 🌙 marker:
   `gh pr list --state open --base <BASE_BRANCH> --json number,title,isDraft,body`.

---

## What goes wrong

- **A tick spawns nothing for hours.** Usually correct — the ready column is
  empty of eligible tickets, or `MAX_AGENTS` are already busy. Check `status`
  before assuming it broke.
- **Every tick blocks on `freegb`, and no agent ever starts.** Measured on an
  8 GB machine **with two agents already running** — the state that decides
  whether a third may start — `freegb` sat between 1.3 and 2.5 GB across ten
  samples, three of them under 2 GB. So the third slot is a coin toss, and the
  cap of 4 is never reached. That is the gate working, not failing. To get real
  concurrency, add RAM — no threshold change creates memory that is not there.
- **All 8 slots busy.** Agents keep their slot when they leave uncommitted work
  or unpushed commits. Read `git -C ~/.claude/agents/agent-N status` before
  closing a window — that is the run's output sitting there.
- **A ticket stuck in `CLAIMED_STATUS` with no PR.** The status moved but the
  agent never got there — a failed spawn, or a window someone closed. Nothing
  recovers it automatically. Move it back to `READY_STATUS` and the next tick
  takes it. Pairing claimed tickets against open PRs is how `status` finds
  these.
- **The machine swaps with agents still under the cap.** `RAM_PER_AGENT_GB` is
  too low for this stack — a Docker or database service costs far more than a
  Vite server. Raise it in the settings table; the probe cannot see it.
- **Chrome tabs pile up.** Tabs are scoped per MCP session, so no agent can
  clear another's. After a night's run:
  `osascript -e 'tell application "Google Chrome" to get URL of every tab of every window'`
- **macOS only.** `cca` needs `open -a Terminal` and APFS `cp -Rc`.
