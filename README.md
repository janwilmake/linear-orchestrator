# orchestrate-linear

A [Claude Code](https://claude.com/claude-code) skill that turns ready Linear
tickets into reviewed pull requests while nobody watches.

It runs on a 15-minute loop. Each tick checks whether the machine has room,
picks one eligible ticket from the ready column, moves it to In Progress, and
spawns an agent that branches, writes the code, tests it, opens a PR and
reviews its own work. It never merges, and it never pushes to your base branch.
The morning job is to read the PRs.

## Change the settings before you run it

Everything project-specific lives in one table at the top of `SKILL.md`, under
**Project settings**. The rest of the file refers to those names, so pointing
the skill at your own repo means editing that table and nothing else.

The values in the table are examples from the repo it was written for. Replace
all of them:

| Setting            | What to put there                                            |
| ------------------ | ------------------------------------------------------------ |
| `REPO`             | Absolute path to your local checkout                         |
| `AGENT_GUIDE`      | Your repo's agent instructions file — usually `CLAUDE.md`     |
| `TRACKER_TEAM`     | Your Linear team name                                        |
| `TICKET_PREFIX`    | Your ticket prefix, e.g. `ENG`                               |
| `READY_STATUS`     | The column the loop takes from                               |
| `CLAIMED_STATUS`   | The column it moves a claimed ticket to                      |
| `ASSIGNEE_TIER_1`  | Whose tickets to take first                                  |
| `ASSIGNEE_TIER_2`  | Whose to fall back to                                        |
| `BASE_BRANCH`      | What to branch from and target                               |
| `DEV_SERVER`       | How your app starts, and the port range to use               |
| `RAM_PER_AGENT_GB` | What one agent costs on your stack — see below               |
| `PROD_SURFACES`    | What the loop must never write to                            |
| `REVIEW_COMMAND`   | Your review command                                          |

## Read this before you run it

**Your repo must have its own agent guide.** The prompt this skill hands to
each agent is four short paragraphs *because* the guide supplies the rest —
branching, local checks, the PR template, testing, security. Point it at a repo
with no such file and you get an unattended agent running with
`--dangerously-skip-permissions` and almost no instructions.

**The agents run unattended, with permission prompts off.** That is the point
of the skill and it is also the risk. Give the loop a repo where the worst an
agent can do is open a bad PR.

**`RAM_PER_AGENT_GB` is the number people get wrong.** The default assumes one
Claude session, one dev server and one Chrome. A stack that runs Docker or a
local database costs far more, and the capacity gate cannot detect this — it
will over-spawn until the machine swaps. Concurrency is bounded by real free
memory, so on a small machine the loop runs one agent at a time no matter what
the cap says.

## Requirements

- macOS. The agent runner needs `open -a Terminal` and APFS `cp -Rc`.
- `cca`, from the `multiclaude` skill. It gives each agent its own repo copy,
  Terminal window and Chrome session. This skill depends on it and does not
  ship it.
- The Linear MCP server, connected to the session that runs the loop.
- `gh`, authenticated.

## Install

```bash
git clone https://github.com/janwilmake/orchestrate-linear.git \
  ~/.claude/skills/orchestrate-linear
```

Then edit the Project settings table, and start it from your repo:

```
/orchestrate-linear
```

`status` reports what is running, `stop` ends the loop and lists the PRs it
produced.
