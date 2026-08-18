# Linear Orchestrator

**Tickets in. Reviewed pull requests out. Nobody watching.**

A [Claude Code](https://claude.com/claude-code) skill that runs your Linear board
overnight and hands you a morning of pull requests to read.

![How it works: you write a ticket, the gate waits for free memory, agents write the code, a fresh agent reviews it, and you get a PR to read](./hero.svg)

## What makes it different

**The whole interface is two surfaces.** A ticket in Linear, and a comment on a
pull request. There is no chat window to steer, no label to remember, no plan to
approve inside the tracker. To change the direction of the work you comment on the
PR, and the loop reads it, answers it by name, and acts on it. That works on a
**merged** PR too, which is where it earns its keep: merge, note the follow-up work
the PR spotted but left out of scope, and the loop turns your note into the next
ticket by itself. Teammates can steer it the same way, on purpose.

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

**It never merges.** Author and reviewer are the same model, so "no blockers left"
is evidence about care, not proof of correctness. The loop stops at a reviewed,
non-draft PR and leaves the merge to a person. That is a choice, not a missing
feature.

## What it does, in order

1. **The gate blocks until there is work** — capacity, your PRs, the Linear ready
   column.
2. **An agent takes the ticket**, moves it to In Progress, branches, opens the
   draft PR before it writes any code, writes the code, tests it in a real browser,
   and stops.
3. **A second agent reviews that PR in a fresh context** — it has the diff, the
   ticket and your repo's agent guide, and none of the reasoning the author talked
   itself into. It posts the review as one comment, makes exactly one fix pass over
   what it found, and corrects the PR body where the diff moved past it.
4. **The PR leaves draft on the five gates**, or stays a draft.
5. **Your comment re-opens any of it.** An unanswered comment on one of its PRs
   outranks every other kind of work on the next tick.

Every agent gets its own repo clone, Terminal window and **real Chrome**, which is
why front-end tickets work here: the screenshots on the PR come from driving the
actual screen, not from a headless guess.

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
LO_FEEDBACK_SINCE="2026-08-18T17:00:00Z"   # the day you installed this
```

`LO_RAM_PER_AGENT` is the one people get wrong: it is a divisor, not a threshold.
Every tick spawns `free memory / LO_RAM_PER_AGENT` agents. The default assumes one
Claude session, one dev server and one Chrome — a stack with Docker or a local
database costs far more, and the probe cannot detect that.

Both `gate.sh` and the tick read these, so there is nothing to edit inside
`SKILL.md`.
