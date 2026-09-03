# linear-orchestrator — what goes wrong

Operational failure modes seen on real runs — the morning-debugging companion
to `SKILL.md`. The tick itself does not read this.

- **A retry loop that reports success without doing the work.** Never write
  `gh ... | tail -1 && break`, or any retry whose condition is a *pipeline's*
  exit status: the shell reports the status of the **last** command in the pipe,
  so `tail` returning 0 hides a `gh` that just 503'd, the loop breaks, and the
  write silently never happened. This skipped a PR's re-draft on one run and the
  tick reported it as done. Make every retry **verify the state** instead —
  re-read `gh pr view <PR#> --json isDraft`, or the labels, or whatever the write
  was supposed to change — and break on the state being right, never on a command
  appearing to succeed. The same rule covers `gh` generally: it 502s and 503s
  often enough that a single unchecked call is a coin toss.
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
- **Drafts pile up and no ticket is ever started.** Working as designed: 2c
  outranks 2d, so a backlog of unfinished drafts stops new work until it clears.
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
- **A PR shows no CI on the commit you care about, and older green runs above
  it.** It conflicts. GitHub runs `pull_request` workflows against a merge commit
  of the branch into the base and cannot build one while the branch conflicts, so
  the workflow never starts — the PR keeps whatever checks its earlier,
  still-mergeable commits earned. Read the head commit's rollup, not the branch's
  run history: `gh pr view <PR#> --json statusCheckRollup`. 2b now catches this,
  but the failure is silent and looks exactly like "CI is a bit slow".
- **Every PR reads `mergeable: UNKNOWN`.** Not a bug and not a conflict. GitHub
  computes mergeability on demand; query again in a few seconds. Never promote on
  `UNKNOWN` and never re-draft on it.
- **`dev NOT refreshed` on every tick.** Somebody left `REPO` dirty or on
  another branch, so the hourly fetch keeps refusing. Every agent spawned
  meanwhile branches from whatever commit `REPO` is parked on. Clean the working
  copy — the loop will not do it for you, on purpose.
- **The session costs a fortune though every tick prints one line.** The bill is
  the transcript, not the tick: the loop runs in one session, so each tick
  re-sends everything before it. Cut what each tick *reads*, not what it prints —
  project `gh` output with `--jq`, read no ticket descriptions unless the queue
  is being rebuilt, and let step 1 end the tick in one line. A ticket cache that
  keeps expiring early is the usual cause.
- **A PR that merges clean but reverts something.** Its branch point predates
  the change it undoes. Check when `REPO` last fast-forwarded against when the
  branch was cut; an agent cannot see this from inside its own clone.
- **Chrome tabs pile up.** Tabs are scoped per MCP session, so no agent can
  clear another's. After a night's run:
  `osascript -e 'tell application "Google Chrome" to get URL of every tab of every window'`
- **macOS only.** `cca` needs `open -a Terminal` and APFS `cp -Rc`.

## The loop stalls with `load N over 10.0` and almost no agents running

An agent left background processes behind. Seen twice, both times a load
generator an agent started to reproduce a flaky test under CPU pressure: it
spawned one busy loop per core and cleaned up with `jobs -p`, which returns
nothing in a non-interactive shell. Ten shells then ran at 100% CPU under
launchd until someone noticed, and the capacity gate refused every tick because
the load it measures was real.

**Find it:** `ps -Ao pid,pcpu,etime,command -r | head` — orphaned shells show a
`PPID` of 1 and an elapsed time far longer than any live agent.

**Fix it:** `pkill -f '<the exact command pattern>'`. Never kill by cpu alone;
a build legitimately runs hot.

**Prevent it:** the agent prompt now tells agents to keep pids explicitly and
kill them in a `trap ... EXIT`. A dev server has the same shape — it survives the
session and holds memory the gate never sees.
