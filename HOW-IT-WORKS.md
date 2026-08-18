# How it works

Two mechanisms carry the whole loop. Neither is something you have to know to run
it — read this when a run looks wrong, or when you want to change it.

## The gate — one `bash` call, no model

```
$ /linear-orchestrator
waiting for work - probe every 60s, give up after 40m
17:22Z NO - slots=1, nothing to take; no drafts; linear ready column empty
17:41Z NO - no slot: ram 2.2gb free, 2.5gb per agent, busy=1; 1 draft(s) waiting
load1=1.80 freegb=2.5 diskgb=855 busy=0 slots=1
FEEDBACK: [{"pr":768,"id":5327779919,"who":"a-teammate","state":"MERGED"}]
DRAFTS: [772]
--- woke after 26m ---
```

`gate.sh` answers "is there anything to do?" in one shot and prints either a `NO`
line **with its reason** or a compact context block. It covers capacity, reaps
leaked dev servers, re-checks the PRs it already promoted, finds comments nobody
has answered, and — the part that used to be impossible from a shell — **reads the
Linear ready column directly**, through the
[`agent-codemode`](https://github.com/janwilmake/agent-codemode) CLI.

`agent-codemode` inherits Claude Code's [Linear MCP](https://linear.app/docs/mcp)
OAuth from the Keychain, so the gate queries Linear with **no token, no model and
no cost**.

Run it as `gate.sh --wait` and it blocks until work exists, then exits — and that
exit is what wakes the model. A night with nothing to do costs zero turns instead
of one every five minutes.

## How it tells your comments from its own

Every agent posts through your own `gh`, so every comment on every PR carries
**your** GitHub login. The author field can never separate a person from a
machine. So the loop marks its own instead:

- Every comment the loop or one of its agents writes starts with `<!-- 🌙 -->`.
- An unmarked comment on a PR the loop opened is a person talking to it.
- Its reply names the comment it answers — `<!-- 🌙 ack:<comment-id> -->` — so
  "already handled" is a fact recorded on GitHub, not in a cache that a `/clear`
  can lose. Nothing is answered twice, and nothing is answered never.
- Every comment gets an answer, including the ones that need no work. Silence is
  the one wrong reply.
- The loop's own comments are collapsed into `<details>`. A person's are not, and
  neither is anything a person must act on.

Set `LO_FEEDBACK_SINCE` to the day you install this. Comments older than it were
written before marking began, so they carry no marker and would all read as
instructions.

## When a run looks wrong

[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) carries the failure modes seen on
real runs — a tick that spawns nothing, `slots` stuck at 0, `mergeable: UNKNOWN`,
a screenshot committed as a file.
