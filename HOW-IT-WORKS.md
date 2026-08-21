# How it works

Two mechanisms carry the whole loop. Neither is something you have to know to run
it — read this when a run looks wrong, or when you want to change it.

## The gate — one `bash` call, no model

```
$ /linear-orchestrator
waiting for work - probe every 60s, give up after 40m
17:22Z NO - slots=1, nothing to take; no drafts; ready column empty
17:41Z NO - no slot: ram 2.2gb free, 2.5gb per agent, busy=1; 1 draft(s) waiting
load1=1.80 freegb=2.5 diskgb=855 busy=0 slots=1
FEEDBACK: [{"ticket":"ENG-431","thread":"70c2…","comment":"70c2…","who":"a-teammate","at":"…"}]
DRAFTS: [772]
--- woke after 26m ---
```

`gate.sh` answers "is there anything to do?" in one shot and prints either a `NO`
line **with its reason** or a compact context block. It covers capacity, reaps
leaked dev servers, re-checks the PRs it already promoted, keeps the ticket
status and the PR draft bit telling one story, and — the part that used to be
impossible from a shell — **reads Linear directly**, through the
[`agent-codemode`](https://github.com/janwilmake/agent-codemode) CLI.

The Linear read is a watermark poll: one `list_issues` call per probe asks
"what moved since the last probe", and only the moved tickets get their
comments fetched, in parallel. A quiet probe costs one subprocess and under a
second; unanswered threads survive in a pending file on disk, so a restart or a
`/clear` forgets nothing.

`agent-codemode` inherits Claude Code's [Linear MCP](https://linear.app/docs/mcp)
OAuth from the Keychain, so the gate queries Linear with **no token, no model and
no cost**.

Run it as `gate.sh --wait` and it blocks until work exists, then exits — and that
exit is what wakes the model. A night with nothing to do costs zero turns instead
of one every five minutes.

## How it tells your comments from its own

Every agent posts through your own Linear login (the MCP posts as you), so the
author field can never separate a person from a machine. So the loop marks its
own instead:

- Every comment the loop or one of its agents writes starts with a visible `🌙`.
  (Not an HTML comment — Linear renders `<!-- -->` as literal text.)
- An unmarked comment on a ticket the loop owns is a person talking to it.
- Its answer is a **reply in your comment's thread**, so "already handled" is
  structural: a thread is answered when its newest human comment is older than
  its newest 🌙 reply. Reply again and the loop wakes again. Nothing is
  answered twice, and nothing is answered never — and the record lives in
  Linear, not in a cache a `/clear` can lose.
- Every comment gets an answer, including the ones that need no work. Silence is
  the one wrong reply.
- The loop's long content collapses into Linear's `>>>` toggles. A person's
  comments do not, and neither does anything a person must act on — a
  `## Blocked on` line, a promotion notice's opening line, an answer.
- One word is a command: a comment that just says **"merge"** on an In Progress
  ticket makes the loop re-check the PR (promoted, mergeable, CI green) and
  merge it, replying with the result. Everything else steers; only that
  executes.

## When a run looks wrong

[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) carries the failure modes seen on
real runs — a tick that spawns nothing, `slots` stuck at 0, `mergeable: UNKNOWN`,
a screenshot committed as a file.
