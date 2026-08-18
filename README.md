# linear-orchestrator

A [Claude Code](https://claude.com/claude-code) skill that turns ready Linear
tickets into reviewed pull requests while nobody watches.

> **macOS only, and Claude-only.** It is a Claude Code skill that drives Claude
> (Opus) agents through [`multiclaude`](https://github.com/janwilmake/multiclaude)
> and reads Linear through
> [`agent-codemode`](https://github.com/janwilmake/agent-codemode). It is not
> model-agnostic, and not portable off macOS — the agent runner needs macOS, and
> the Linear token is read from the macOS Keychain.

It runs on a 5-minute loop, in the foreground, so you can watch each tick land
in the terminal. Each tick measures free memory first and spawns one agent per
`RAM_PER_AGENT_GB` of it (default 2.5), so the machine reaches full concurrency
in one tick rather than climbing to it one agent at a time. Each agent takes an
eligible ticket from the ready column, moves it to In Progress, then branches,
writes the code, tests it, opens a draft PR, reviews its own work, and fixes the
blockers that review found.

It never merges, and it never pushes to your base branch. A review by the agent
that wrote the code is the weakest evidence available, so the fix pass buys you
a cleaner diff, not a mergeable one. The morning job is to read the PRs.

## The gate — one `bash` call per tick

Every tick starts with `gate.sh`, which does the whole "is there anything to do?"
check in one shot and prints either `NO` (end the tick) or a compact context
block. It covers capacity (free RAM, load, disk), reaps leaked dev servers,
re-checks the loop's promoted PRs, and — the part that used to be impossible from
a shell — **reads the Linear ready column directly**, through the
[`agent-codemode`](https://github.com/janwilmake/agent-codemode) CLI.

`agent-codemode` inherits Claude Code's Linear OAuth from the Keychain, so the
gate queries Linear with **no token, no model, and no cost**. The eligible-ticket
ids fold into the gate's change-hash, so a new ready ticket is seen on the next
5-minute gate — not only on the 30-minute queue rebuild.

## Configure with `.env`, not the skill file

All the values that change per user live in **`.env`** beside `SKILL.md`. Copy
the template and fill it in — `.env` is gitignored, so your paths and names never
reach the repo, which is what lets the skill be a symlink to a checkout:

```bash
cp .env.example .env
$EDITOR .env
```

```bash
LO_REPO="/path/to/your/repo"   # local checkout the agents clone from
LO_BASE="dev"                  # base branch
LO_TEAM="Your Team"            # Linear team name
LO_PREFIX="ENG"                # ticket id prefix
LO_TIER1="Preferred Assignee"  # display name; unassigned is always eligible
LO_TIER2="Fallback Assignee"   # display name
LO_RAM_PER_AGENT="2.5"         # GB per agent (claude + vite + chrome)
```

Both `gate.sh` and the tick read these, so there is nothing to edit inside
`SKILL.md`.

## Read this before you run it

**Your repo must have its own agent guide.** The prompt this skill hands to each
agent is eight short paragraphs *because* the guide supplies the rest —
branching, local checks, the PR template, testing, security. Point it at a repo
with no such file and you get an unattended agent running with
`--dangerously-skip-permissions` and almost no instructions.

**The agents run unattended, with permission prompts off.** That is the point of
the skill and it is also the risk. Give the loop a repo where the worst an agent
can do is open a bad PR.

**`LO_RAM_PER_AGENT` is the number people get wrong.** It is a divisor, not just a
threshold: every tick spawns `free memory / LO_RAM_PER_AGENT` agents. The default
of 2.5 assumes one Claude session, one dev server and one Chrome. A stack that
runs Docker or a local database costs far more, and the probe cannot detect this
— set it too low and the loop over-spawns until the machine swaps. Concurrency is
bounded by real free memory, so on a small machine the loop runs one or two
agents no matter what the cap says.

## Requirements

- **macOS.** The agent runner needs `open -a Terminal` and APFS `cp -Rc`; the
  Linear OAuth token is read from the macOS Keychain.
- **[`agent-codemode`](https://github.com/janwilmake/agent-codemode)**, on `PATH`
  (or at `~/.local/node/bin/agent-codemode`). The gate uses it to read Linear.
  Without it the gate still runs, but skips the Linear check and says so.
- **`cca`**, from the
  [`multiclaude`](https://github.com/janwilmake/multiclaude) skill — it gives each
  agent its own repo copy, Terminal window and Chrome session. This skill depends
  on it and does not ship it.
- **The Linear MCP server**, connected to the session that runs the loop.
- **`gh`**, authenticated, and **`jq`**.

## Install

Clone it as the skill (or clone elsewhere and symlink
`~/.claude/skills/linear-orchestrator` at it — the `.env` travels with the
directory):

```bash
git clone https://github.com/janwilmake/linear-orchestrator.git \
  ~/.claude/skills/linear-orchestrator
cd ~/.claude/skills/linear-orchestrator
cp .env.example .env && $EDITOR .env
```

Then start it from your repo:

```
/linear-orchestrator
```

`status` reports what is running; `stop` ends the loop and lists the PRs it
produced.
