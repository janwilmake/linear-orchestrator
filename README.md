# Linear Orchestrator

**Tickets in. Reviewed pull requests out. Nobody watching.**

A [Claude Code](https://claude.com/claude-code) skill that runs your Linear board
overnight and hands you a morning of pull requests to read.

![How it works: you write a ticket, the gate waits for free memory, agents write the code, a fresh agent reviews it, and you get a PR to read](./hero.svg)

## What makes it different

**The whole interface is one surface: the ticket.** Anyone writes a ticket in
their own words; the loop grooms it (your words kept verbatim, a grounded
rewrite beside them), works it, and everything a PR body used to hold — the
problem, the solution, the decisions, the screenshots, the review — lands on
the ticket. The PR body is two lines and a link. To steer the work you comment
on the ticket — from the app, from your phone — and the loop answers in the
thread and acts on it. That works on a **merged** ticket too, which is where it
earns its keep: merge, note the follow-up work the diff spotted but left out of
scope, and the loop turns your note into the next ticket by itself. GitHub
comments are deliberately not read at all.

**The status is one bit: whose ball is it.** Default Linear statuses only —
`Todo` means the machine holds it (ready, being written, being reviewed, even
conflicting), `In Progress` means a person owes it a look (a promoted PR, a
blocker, a research decision), and Linear's own git automation moves it on
merge. Nothing in the backlog is ever touched: moving a ticket to `Todo` is the
start signal, and the only one.

**Draft means something.** A PR leaves draft only on evidence — a review, a fix
pass over that review, a screenshot when a user can see the change, no merge
conflict, and CI green on the head commit. It never leaves draft on an agent's
say-so. So what is not a draft in the morning is what is actually ready, and the
drafts are the pile you can ignore until you have time.

**Idle costs nothing.** Nothing runs until there is work. The gate probes
capacity, your open PRs and the Linear ready column every 60 seconds **in pure
shell** — no model call, no turn started. A night with an empty board costs
nothing at all, not "not much".

**It runs on your machine, on the Claude you already pay for.** No hosted sandbox,
no per-session credit, no repo access granted to a third party. That also means it
uses whatever the machine has: it measures free memory every probe and runs as many
agents as will really fit — one per `LO_RAM_PER_AGENT` gigabytes — so parallelism
is bounded by your laptop rather than by a plan.

**It never merges on its own judgment.** Author and reviewer are the same
model, so "no blockers left" is evidence about care, not proof of correctness.
The loop stops at a reviewed, non-draft PR and leaves the decision to a person —
who can review and merge without leaving Linear (the ticket links the review
page), or just comment **"merge"** on the ticket and let the loop execute it
after re-checking that the PR is still mergeable and green. The human decides;
the loop only ever executes.

## What it does, in order

1. **The gate blocks until there is work** — capacity, your PRs, unanswered
   ticket comments, the Linear ready column.
2. **An agent takes the ticket**, grooms it (your words verbatim, a grounded
   rewrite), branches, opens the two-line draft PR before it writes any code,
   writes the code, tests it in a real browser, and keeps the ticket current as
   it goes. The ticket stays in `Todo` the whole time — the machine's ball.
3. **A second agent reviews that PR in a fresh context** — it has the diff, the
   ticket and your repo's agent guide, and none of the reasoning the author
   talked itself into. It posts the review as one comment on the ticket, makes
   exactly one fix pass over what it found, and corrects the ticket where the
   diff moved past it.
4. **The PR leaves draft on the five gates**, or stays a draft. Promotion moves
   the ticket to `In Progress` — now it is your ball, and the ticket says so.
5. **Your comment re-opens any of it.** An unanswered comment on one of its
   tickets outranks every other kind of work on the next tick.

Every agent gets its own repo clone, Terminal window and **real Chrome**, which is
why front-end tickets work here: the screenshots on the ticket come from driving
the actual screen, not from a headless guess.

The mechanics — the shell gate, and how the loop tells your comments from its own —
are in [`HOW-IT-WORKS.md`](./HOW-IT-WORKS.md).

## Who this is for

People who already run coding agents locally and would rather spend a machine than
a per-seat credit. The install is honestly longer than "connect GitHub", and the
constraints are real:

- **macOS only, and Claude only.** It drives Claude (Opus) agents through
  [`multiclaude`](https://github.com/janwilmake/multiclaude) and reads Linear
  through [`agent-codemode`](https://github.com/janwilmake/agent-codemode), which
  reads its OAuth from the macOS Keychain.
- **One machine.** Parallelism caps at what one laptop's memory holds.
- **`--dangerously-skip-permissions` is required.** The agents run unattended with
  permission prompts off. That is the point, and it is also the risk — give the
  loop a repo where the worst an agent can do is open a bad PR.
- **Your repo needs its own agent guide** (`CLAUDE.md`). The prompt handed to each
  agent is short *because* the guide supplies branching, local checks, the PR
  template, testing and security.

## Install and run

You also need `gh` (authenticated), `jq`, and the
[Linear MCP server](https://linear.app/docs/mcp) connected to the session that runs
the loop.

```bash
git clone https://github.com/janwilmake/linear-orchestrator.git \
  ~/.claude/skills/linear-orchestrator
cd ~/.claude/skills/linear-orchestrator
cp .env.example .env && $EDITOR .env
```

Then start it from your repo:

```bash
cd /path/to/your/repo
claude --dangerously-skip-permissions
```

```
/linear-orchestrator
```

`status` reports what is running; `stop` ends the loop and lists the PRs it
produced.

## Configure with `.env`, not the skill file

All the values that change per user live in **`.env`** beside `SKILL.md`. It is
gitignored, so your paths and names never reach the repo — which is what lets the
skill be a symlink to a checkout:

```bash
LO_REPO="/path/to/your/repo"   # local checkout the agents clone from
LO_BASE="dev"                  # base branch
LO_TEAM="Your Team"            # Linear team name
LO_PREFIX="ENG"                # ticket id prefix
LO_TIER1="Preferred Assignee"  # display name; unassigned is always eligible
LO_TIER2="Fallback Assignee"   # display name
LO_RAM_PER_AGENT="2.5"         # GB per agent (claude + vite + chrome)
LO_MAX_AGENTS="4"              # hard ceiling on concurrent agents
```

The status names (`Todo` / `In Progress` / `In review`) are overridable too —
see `.env.example`. One piece of Linear setup is required: in your team's
**Workflows & automations**, set *draft PR open* and *PR review activity* to
**No action**, and *PR or commit merge* to your `In review` status. The first
two would fight the status contract; the third is the merged-ticket move done
natively.

`LO_RAM_PER_AGENT` is the one people get wrong: it is a divisor, not a threshold.
Every tick spawns `free memory / LO_RAM_PER_AGENT` agents. The default assumes one
Claude session, one dev server and one Chrome — a stack with Docker or a local
database costs far more, and the probe cannot detect that.

Both `gate.sh` and the tick read these, so there is nothing to edit inside
`SKILL.md`.
