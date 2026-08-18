# Linear Orchestrator

**Tickets in. Reviewed pull requests out. Nobody watching.**

A [Claude Code](https://claude.com/claude-code) skill that runs your Linear board
overnight and hands you a morning of pull requests to read.

![How it works: you write a ticket, the gate waits for free memory, agents write the code, a fresh agent reviews it, and you get a PR to read](./hero.svg)

## What you stop doing

**You stop talking to agents.** There is no chat window to steer, no context to
re-explain, no session to catch up on. You write a ticket in Linear and you read a
pull request in GitHub. To change the direction of the work you leave a **comment
on the PR** — and the loop reads it, answers it by name, and acts on it. That
works on a merged PR too, which is where it earns its keep: merge, note the
follow-up work the PR spotted but left out of scope, and the loop turns your note
into the next ticket by itself. No label to remember. Teammates can steer it the
same way, on purpose.

**You stop rationing the machine.** The loop measures free memory, load and disk
every minute and runs as much parallel work as the machine can actually hold —
one agent per `LO_RAM_PER_AGENT` gigabytes of real free memory, re-measured every
probe. When there is nothing to do it costs nothing at all: the gate blocks in
pure shell and wakes the model only when work exists.

**You stop reading transcripts to find the decision.** Every judgment call an
agent made, the evidence behind it and the screenshots of what changed land on the
PR — under `## Decisions`, in the review comment, in the fix-pass reply. The diff
carries its own argument, so the review is the artifact and the chat log is
nothing you need.

## What it does, in order

1. **A gate blocks until there is work** — capacity, your PRs, the Linear ready
   column. It probes every 60 seconds in pure shell, so a quiet night spends no
   tokens and starts no turns.
2. **An agent takes the ticket**, moves it to In Progress, branches, writes the
   code, tests it in a real browser, and opens a **draft** PR. Then it stops.
3. **A second agent reviews that PR in a fresh context** — it has the diff, the
   ticket and your repo's agent guide, and none of the reasoning the author talked
   itself into. It posts the review as one comment, makes exactly one fix pass over
   what it found, and corrects the PR body where the diff moved past it.
4. **The PR leaves draft only on evidence**: a review, a fix pass over it, a
   screenshot when a user can see the change, no merge conflict, and CI green on
   the head commit. Draft is therefore the honest signal — what is ready in the
   morning is what is not a draft.
5. **Your comment re-opens any of it.** An unanswered comment on one of its PRs
   outranks every other kind of work on the next tick.

It never merges, never pushes to your base branch, and never writes to
production. Two agents of the same model are still one model, so the review is
evidence about care, not proof of correctness. The morning job is to read the PRs.

The mechanics behind steps 1 and 5 — the gate, and how the loop separates your
comments from its own — are in [`HOW-IT-WORKS.md`](./HOW-IT-WORKS.md).

## Install and run

**macOS only, and Claude-only.** It drives Claude (Opus) agents through
[`multiclaude`](https://github.com/janwilmake/multiclaude) and reads Linear
through [`agent-codemode`](https://github.com/janwilmake/agent-codemode), which
needs the macOS Keychain. You also need `gh` (authenticated), `jq`, and the
[Linear MCP server](https://linear.app/docs/mcp) connected to the session that
runs the loop.

`cca`, from `multiclaude`, is what gives each agent its own repo clone, Terminal
window and **Chrome instance** — the reason the work runs through `cca` and not
Claude Code subagents, which would share one browser session and fight over the
same tabs. This skill depends on it and does not ship it.

```bash
git clone https://github.com/janwilmake/linear-orchestrator.git \
  ~/.claude/skills/linear-orchestrator
cd ~/.claude/skills/linear-orchestrator
cp .env.example .env && $EDITOR .env
```

Then start it from your repo, in a session launched with
`--dangerously-skip-permissions`:

```bash
cd /path/to/your/repo
claude --dangerously-skip-permissions
```

```
/linear-orchestrator
```

`status` reports what is running; `stop` ends the loop and lists the PRs it
produced.

Three things to know before the first night:

- **The flag is required.** Without it every `cca` call, and the git and `gh`
  commands inside each agent, stops on a permission prompt nobody is awake to
  answer, and the loop stalls on the first tick.
- **Your repo must have its own agent guide** (`CLAUDE.md`). The prompt handed to
  each agent is short *because* the guide supplies branching, local checks, the PR
  template, testing and security. Point the loop at a repo with no guide and you
  get an unattended agent with almost no instructions. Give it a repo where the
  worst an agent can do is open a bad PR.
- **`LO_RAM_PER_AGENT` is a divisor, not a threshold.** Every tick spawns
  `free memory / LO_RAM_PER_AGENT` agents. The default of 2.5 assumes one Claude
  session, one dev server and one Chrome; a stack with Docker or a local database
  costs far more, and the probe cannot detect that. Set it too low and the loop
  over-spawns until the machine swaps.

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

Both `gate.sh` and the tick read these, so there is nothing to edit inside
`SKILL.md`.
