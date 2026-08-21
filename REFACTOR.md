# Refactor: move the conversation to Linear, keep the state on GitHub

Status: **draft for review — nothing here is applied yet.**
Inventory snapshot: 2026-08-21. Re-run the inventory commands before executing;
the numbers move every night the loop runs.

## The end state, in one paragraph

Linear is where humans and the loop talk; GitHub is where code state lives. A
human writes a ticket in any words, in Backlog. Moving it to **Todo** is the
start signal — the loop grooms it (verbatim input preserved, grounded rewrite
added), works it, and everything it used to write into the PR body and PR
comments now goes to the ticket. The PR body is one line: the 🌙 marker and the
ticket link. The loop reads feedback **only** from Linear comments. The ticket
status carries exactly one bit — whose ball is it: **Todo = the machine's, In
Progress = the human's** — and it mirrors the PR's draft bit. Draft/promote,
CI, and mergeable stay on GitHub, read via `gh` as today.

## 0. Verified assumptions (2026-08-21, live against the workspace)

- `>>>` collapsible toggles round-trip through the MCP; `<details>` does NOT
  (renders as literal text).
- Screenshot upload works end to end without a browser: `prepare_attachment_upload`
  → `curl PUT` (60s signed URL, one file at a time) → `![...](assetUrl)` mid-text.
  Renders **inline at the markdown position**, in bodies (inside toggles) and in
  comments — verified visually on HYR2-1016.
- **A new comment bumps the issue's `updatedAt`** to the comment's timestamp,
  and bumps the thread root's `updatedAt` too. The watermark poll therefore
  sees all feedback. Verified.
- Thread replies carry `parentId` through `save_comment` and `list_comments`.
  Acks-as-thread-replies works. Verified.
- **"via MCP" is UI-only** — the comments API exposes no source field
  (`author` is the user, `onBehalfOf` null). The visible 🌙 marker remains the
  only machine-readable loop-vs-human discriminator. Do not design against the
  UI tag.
- Linear's GitHub integration auto-attaches PRs to tickets by branch name
  (seen live: HYR2-992 ↔ PR #814).
- Gate call costs: one `agent-codemode` Linear call ≈ 0.8s; 4 parallel comment
  fetches ≈ 1.5s.
- Descriptions export issue mentions as embedded `<issue id=… href=…>` tags —
  patches must preserve them verbatim. Bare ticket ids in prose are auto-linked
  into such tags on save, and auto-create a Related-issue relation.
- A hand-typed human comment (desktop and thread reply) arrives byte-identical
  to an MCP one through the API — 🌙-absence is the whole discriminator.
  Verified live. It also exposed the ack-ordering rule (§4).
- **Git automations already exist and are configured** (team settings →
  Workflows & automations). As found on 2026-08-21: draft PR open →
  In Progress, PR/commit open → In Progress, PR review activity → In review,
  PR ready for merge → No action, PR/commit merge → In review. The merge rule
  is exactly the new model; the draft-open and review-activity rules would
  yank tickets out of Todo and must be set to **No action** at cutover (§8.7).
- **Image portability**, verified live: the bare `uploads.linear.app` asset URL
  returns 401 (auth-gated — Linear images can never be hot-linked from GitHub);
  the `?signature=` JWT the API hands out lives **5 minutes** and serves the
  exact original bytes (download for re-hosting is possible while fresh);
  and an asset uploaded to one ticket **renders inline when its bare URL is
  embedded in any other ticket or comment in the workspace** — Linear re-signs
  it on save. Aggregation (e.g. a release ticket collecting every ticket's
  screenshots) is therefore URL-reference only, no re-upload.
- **§8.3 dry run: done on PR #823 / HYR2-999** (2026-08-21, loop live but PR
  hours from pickup). Ticket now carries the full target anatomy — Human input
  (verbatim) + Grounded ticket + the eight PR-body sections as toggles — and
  renders correctly, mermaid and tables included. Backup in the session
  scratchpad (`dryrun-backup/pr-823.json`). The PR-body slim was deliberately
  deferred to migration night: the running old-rules loop would fight a slim
  body, and `gh pr edit --body-file` carries no mechanical risk worth testing
  against that.

Nothing remains to verify before cutover.

Design consequence of the Linear-as-critical-path shift: a failed Linear query
in the gate is no longer a `notes:` footnote — it must print `GATE-ERROR` and
wake the model, because a deaf gate now means unanswered humans, not just
missed tickets.

## 1. The status model

Default Linear statuses only. No new statuses, no orchestrator labels.

| Status | Meaning | GitHub mirror |
| --- | --- | --- |
| Backlog / Planned / Ideas / To Discuss | Human territory. The loop never reads or touches any backlog-type status. | — |
| **Todo** | The machine holds the ball: ready, being groomed, implemented, reviewed, fixed, conflicting, CI-red. | Draft PR, or none yet |
| **In Progress** | The human holds the ball: read the promoted PR, answer a blocker, pick a research option, do what the loop cannot. Always accompanied by a 🌙 comment saying *what*. | Promoted PR |
| In review | Merged, on staging, until verified in production. Human-managed. | Merged PR |
| Done / Canceled / Duplicate | Human-managed. The loop never sets these. | — |

Invariant: **`isDraft` ⇔ Todo, promoted ⇔ In Progress**, for every ticket the
loop owns. The gate checks the invariant on every probe and repairs drift in
the loop's own tickets only (🌙 in the PR body is still the ownership test).

Transitions the loop makes:

| Trigger | Move | Also |
| --- | --- | --- |
| Human drags ticket to Todo | — | Groom on pickup; work begins |
| Five gates pass, PR promoted | Todo → In Progress | `gh pr ready`; promotion comment on the ticket |
| Agent blocked (credential, decision, research options) | Todo → In Progress | Promote the PR; blocker is the comment's opening line |
| Ticket must be skipped (prod-only, missing artifact) | Todo → In Progress | Comment names the blocker — no PR exists, the comment is the payload |
| Human comment asks for work | In Progress → Todo | `gh pr ready --undo`; thread-reply ack; dispatch rework |
| Human comment is a question / "leave it" | — | Thread-reply ack with the answer; stays In Progress |
| Promoted PR goes conflicting or CI-red | In Progress → Todo | `gh pr ready --undo`; comment why; dispatch fix |
| PR merged | In Progress → In review | Configure Linear's GitHub integration to do this natively; the loop does nothing |

What this deletes: `CLAIMED_STATUS` and claim-via-status, the Backlog fallback
pass in 2d, the `invalid` label flow, `FEEDBACK_LOGINS` + the `ack:<id>`
apparatus, the GitHub comment scan, and the browser-driven screenshot upload.

## 2. The claim, without the status

Claim-by-status is gone (a worked ticket stays Todo), so the double-spawn guard
becomes two overlapping mechanisms, both already proven in this codebase:

1. **Dispatch marker, ticket-scoped.** On spawn, the tick writes the slot
   number to `~/.claude/linear-orchestrator/dispatched/<TICKET-ID>` in the same
   Bash call — exactly the existing `dispatched/<PR#>` mechanism, extended to
   ticket ids. The gate treats the ticket as in hand while that slot's
   `agent-N.lock` pid is alive, and deletes the marker itself when it is not.
   Covers spawn → draft-PR-open, the blind window.
2. **Open-PR check.** The queue rebuild already drops any ticket whose id
   appears in an open PR head branch. Covers draft-PR-open → merge.

Known limit, accepted: the marker lives on one machine's disk. Two machines
running the loop against one board cannot see each other's claims.

## 3. Ticket anatomy

Linear collapsible sections use `>>>` (native toggle syntax; verified round-trip
through the MCP — `<details>` does NOT work, it renders as literal text).

```
🔗 [Review & merge in Linear](<diff appUrl>) · [PR #<n> on GitHub](<PR url>)

>>> Human input (verbatim)

exactly what the human typed, never edited, never reformatted

>>>

>>> Grounded ticket

the AI rewrite: problem, scope, acceptance criteria

>>>

(then the sections that used to live in the PR body:)
>>> Problem          — with the before screenshot beside its sentence
>>> Solution         — with the after screenshot
>>> Decisions        — same rules as today: two or more real options, or omit
>>> Out of scope & Suggestions — numbered, never renumbered
## Blocked on        — never collapsed, top of the description, when present
```

- **Grooming** happens as the implementing agent's first action on pickup.
  Ungroomed is detected structurally: no `>>> Human input` section. No label,
  no cache. The verbatim section is what makes rewriting the human's words safe.
- Section updates use `save_issue`'s anchored `patch` ops, not full-description
  rewrites — concurrent human edits fail the anchor loudly instead of being
  clobbered.
- **Screenshots** upload through the Linear MCP
  (`prepare_attachment_upload` → `create_attachment_from_upload`) and embed in
  the description. The entire drive-github.com-and-drag-the-file flow is deleted.
- Research tickets: findings + numbered options in the ticket description,
  `## Blocked on` asks for a number, PR stays a near-empty diff, promoted +
  In Progress. "do 2" arrives as a Linear comment.

The PR body becomes, in full:

```
🌙 opened by the nightly orchestrator. Not seen by a human.
Everything about this change: <ticket URL>
```

The 🌙 stays load-bearing: it is how the gate tells the loop's PRs from human
PRs. Linear's GitHub integration links the PR onto the ticket via the branch
name, so the two references complete the loop.

**Release PRs follow the same shape.** A release PR's evidence lives in a
release ticket in Linear that aggregates the shipped tickets: one line + the
before/after screenshots per ticket, pulled in by **bare asset-URL reference**
(verified: a workspace asset renders inline in any ticket or comment, no
re-upload). The release PR body itself is the two-line marker + that release
ticket's link. Linear images can never be embedded on GitHub — the bare URL is
401 and signatures die in 5 minutes — which is not a limitation to work
around but the design working: the evidence lives where the conversation
lives.

## 4. Comments and feedback

- Everything the loop writes — reviews, fix-pass replies, promotion notices,
  de-gate notices, acks, skip explanations — is a **Linear comment on the
  ticket**, first line `🌙`, details inside `>>>` toggles. GitHub PR comments
  from the loop: none, ever.
- The marker must be the **visible** `🌙`, not an HTML comment. `<!-- -->`
  survives the API round-trip but **renders as literal text in the Linear UI**
  (`<!-- 🌙 →`, the `-->` mangled into an arrow) — user-confirmed on a real
  loop comment, 2026-08-21. Never write an HTML comment into Linear anywhere.
  (On GitHub they stay invisible and keep working as before.)
- **Acks are thread replies, and order matters.** A thread is answered iff its
  **newest non-🌙 comment is older than its newest 🌙 reply** — existence of a
  🌙 reply is not enough, because a human can reply again into an already-acked
  thread (seen on the live test: a human "heyyy" after the ack would be
  silently swallowed by an existence test). The `ack:<id>` bookkeeping is
  deleted — threading plus ordering makes it structural. Every human comment
  still gets an ack, including "noted, nothing to do".
- **GitHub comments are ignored entirely.** No scan, no ack, by decision.
- The review itself still reads the diff on GitHub (`gh pr diff`, `/review`);
  only where it *lands* changes.
- Who counts: any human comment on a loop-owned ticket. (The author field is
  as useless on Linear as on GitHub — the MCP posts as the user — hence 🌙.)

## 4b. Reviewing and merging from Linear

Every PR already exists in Linear as a **diff** with its own review page
(`linear.app/hyre2/review/…`), reachable from the ticket's Diffs rail and the
sidebar Reviews list. The workspace is set to review PRs in Linear by default.
Verified live on PR #822 (`mergeStatus: ready`) and #823.

- **The PR link line** is the first line of every ticket description, above
  everything including `## Blocked on`:

  `🔗 [PR #<n> on GitHub](<PR url>/files) · <the bare GitHub PR URL>`

  Two normalizer facts, both verified: a bare PR conversation URL is ALWAYS
  converted into Linear's rich PR chip, whose link goes to the **Linear
  review page** — it cannot be kept as a GitHub link. The `…/pull/<n>/files`
  form escapes the converter and survives as a true GitHub link (landing on
  the diff tab). So the line carries both: the `/files` link for "take me to
  GitHub", and the bare URL for the chip, which shows PR state and opens the
  Linear review. The implementing agent prepends this line right after opening
  the draft PR; the migration adds it to all 25 open tickets.
- **Merging, human paths**: the review page's own controls, or any Claude
  session via `merge_diff` / `submit_diff_review` ("merge HYR2-997's PR"
  from a phone works).
- **Merging, comment-driven** — the loop executes an explicit merge order:
  - The command is a comment on the ticket whose trimmed text **starts with
    the word `merge`** (case-insensitive) and contains nothing beyond a short
    tail ("merge", "merge it", "merge pls"). A comment that merely *mentions*
    merging mid-sentence is ordinary feedback, never a command.
  - Guards, checked at execution time via `get_diff`: the PR is promoted
    (ticket In Progress), `mergeStatus` is ready, and CI on the head commit is
    green. Any guard failing → no merge, thread-reply ack saying exactly which
    guard and what would clear it.
  - On success: `merge_diff` (repo default method), thread-reply ack with the
    result. The merged→In review move is the git automation's job.
  - The invariant is rephrased, not weakened: **the loop never decides to
    merge; it may execute an explicit human merge order.** Author and reviewer
    are still one model, and "no blockers left" still earns nothing — a merge
    happens only on a human's word.

## 5. gate.sh changes

| Piece | Today | After |
| --- | --- | --- |
| Feedback scan | One repo-wide `gh api issues/comments` + `ack:<id>` matching | Linear watermark poll (below) |
| `FEEDBACK_SINCE` / `FEEDBACK_LOGINS` | Config | Deleted (`FEEDBACK_SINCE` becomes the watermark's initial value at cutover) |
| INVALID line | `invalid` label scan | Deleted |
| REGATE | Detect + report | Same, plus the tick now also moves the ticket In Progress → Todo |
| Todo candidates | Only when `slots > 0` | Same query, but it rides the watermark poll, so it runs on every probe — a NO at `slots=0` can finally mention the board |
| Dispatch markers | `dispatched/<PR#>` | Plus `dispatched/<TICKET-ID>`, same lifecycle |
| DRAFTS / CI / mergeable / promotion | `gh` | Unchanged |

**The watermark poll**, every probe (~0.8s, benchmarked):

```
list_issues(team, updatedAt: "> <watermark>", orderBy: updatedAt,
            fields: [status, updatedAt, labels])
```

- Nothing moved → quiet probe, one call, done.
- Issues moved → fetch `list_comments` for just those issues, in parallel
  (4 calls ≈ 1.5s, benchmarked). New human comment with no 🌙 thread-reply →
  `FEEDBACK` line. Status flips fold into the state hash.
- The watermark is a **persisted timestamp file**, and it may advance on any
  successful probe — quiet ones included — because the **pending file, not the
  watermark, is the ledger of what is owed**: an unanswered thread stays there
  until a fetch shows it answered. On failure nothing advances. A missing
  watermark re-initializes to the full feedback window, so a wiped state dir
  re-scans instead of forgetting.
- Budget guard: a probe is one `list_issues` always, plus comment fetches only
  for moved issues. Worst case stays under ~3s against a 60s interval;
  rate-limit exposure ~60–120 requests/hour.
- `FEEDBACK` entries now carry ticket ids + comment ids, not PR ids.

## 6. SKILL.md changes, by section

- **Settings table**: drop `LO_FEEDBACK_SINCE`, `LO_FEEDBACK_LOGINS`; drop
  `CLAIMED_STATUS`, `INVALID_LABEL` from the fixed list; `READY_STATUS` becomes
  strictly `Todo` (no Backlog fallback — backlog-type is never read).
- **2a** rewritten: feedback = Linear comments; ack = thread reply; the
  `MERGED`/`OPEN`/`CLOSED` routing keys on the ticket's PR state as before but
  acts on the ticket status; the `invalid` flow deleted; the numbered-options
  interface ("do 2") unchanged in spirit, now read from ticket sections; the
  never-duplicate-a-ticket rule unchanged.
- **2b** (de-gate): plus In Progress → Todo on re-draft.
- **2c** (finish drafts): same five gates; classification evidence moves —
  review/fix-pass are Linear comments on the ticket, screenshot test looks for
  `uploads.linear.app` in the ticket description (not `user-attachments` in the
  PR body); `## Blocked on` is tested in the **ticket description**, same
  own-line grep rule; promotion moves the ticket to In Progress.
- **2d**: eligibility unchanged except skips now move the ticket to In
  Progress with the blocker comment (so `skipped` in QUEUE_CACHE shrinks to a
  transient de-dup, or goes away entirely — the status now carries the fact).
- **Step 3** ("claim before spawning") rewritten: verify still-Todo and
  still-in-tiers, write the dispatch marker, comment "picked up" — **no status
  move, no assignee change on pickup**. Assign to `ASSIGNEE_TIER_1` at
  *promotion* instead, when a human first needs to look.
- **Step 4**: dispatch marker now written for every spawn, fresh tickets
  included (ticket-scoped).
- **Agent prompts** (all five): open the draft PR with the two-line body and
  never edit it again; keep the *ticket* current instead (`save_issue` patch);
  groom first if ungroomed; all comments to Linear with visible 🌙; `>>>` not
  `<details>`; screenshots via MCP upload, never `git add`, never the GitHub
  web UI; teardown unchanged.

## 7. The screenless loop

Its `☎️` relay posts call decisions as GitHub PR comments today — invisible to
the new gate. Same refactor window: it posts to the Linear ticket instead,
keeps `☎️` + `Already ticketed:` so the duplicate-ticket guard still works.
Its read pass (paper/brief) also learns the new status semantics: Todo = with
the machine, In Progress = waiting on you — that distinction is exactly what
the morning call wants to read out.

## 8. Migration of existing data

Inventory at snapshot (verify before executing):

- **25 open PRs** against `dev`: **13 drafts** (#823, 815, 814, 812, 806, 804,
  802, 791, 789, 787, 779, 776, 773 — of which 6 CONFLICTING: #802, 791, 789,
  787, 779, 776) and **12 promoted**, all MERGEABLE (#822, 821, 820, 819, 818,
  817, 813, 803, 801, 800, 799, 770).
- **30 In Progress tickets**: 13 with draft PRs, 12 with promoted PRs, 5 with
  no open PR (HYR2-987, 982, 963, 717, and 894 which is Tamás's — human-owned,
  untouched).
- **13 Todo tickets**, including known skip candidates (HYR2-1014 runs a prod
  runbook, HYR2-1013 is a vendor conversation, HYR2-972 sits in the queue's
  skipped list).

Steps, in order, loop **stopped**:

0. **Backup dump, before anything writes.** One file per system, dated, kept
   outside the repo: `gh pr list --state all --limit 200 --json
   number,title,body,isDraft,state,headRefName,comments` and the full Linear
   team export (`list_issues` with description + status + labels, and
   `list_comments` per non-done ticket). Every later step becomes reversible by
   construction: nothing is deleted anywhere in this migration, only added or
   re-stated, and the dump is the proof of the before-state.
1. **Final GitHub feedback sweep.** Run the old scan once; ack every pending
   comment on GitHub with a pointer ("steering moved to the Linear ticket:
   <link>"). Nothing may be orphaned mid-conversation. After this, GitHub
   comments are dead to the loop.
2. **Status realignment** (one `save_issue` each):
   - 13 tickets with draft PRs → **Todo** (HYR2-999, 986, 992, 988, 984, 981,
     980, 969, 960, 961, 956, 954, 950).
   - 12 tickets with promoted PRs → stay **In Progress**. Set assignee if
     missing.
   - 5 In Progress without an open PR: audit each. PR merged → **In review**;
     genuinely stranded (no PR, no agent) → **Todo** with a 🌙 comment saying
     the orchestrator found it stranded; human-owned (HYR2-894) → untouched.
3. **Content migration, one pass per open PR** (25 agents' worth of mechanical
   work, or one scripted pass via `agent-codemode`):
   - Prepend the PR link line (§4b) — `get_diff` on the PR URL returns the
     review `appUrl`.
   - Copy the PR body's sections into the ticket description as `>>>` toggles
     (Problem, Solution, Decisions, Out of scope, `## Blocked on` uncollapsed).
     Re-upload `user-attachments` screenshots to Linear or link them —
     decide by cost; linking is acceptable, GitHub keeps hosting them.
   - Copy the PR's 🌙 comments (review, fix-pass reply) to the ticket as 🌙
     comments, each prefixed with its **original timestamp** in the text.
   - Replace the PR body with the two-line marker + link body.
   - **Seed `WORK_CACHE`** with each draft's classification (computed from the
     old GitHub evidence during this pass). This matters: migrated comment
     timestamps are all post-cutover, so the "review dated after head commit"
     test cannot be trusted for migrated PRs — the seeded cache is the bridge,
     and it drains naturally as each draft finishes.
4. **Skip-rule application.** Move the known Todo skip candidates to In
   Progress with their blocker comments (HYR2-1014, 1013; re-judge 972).
   Everything else in Todo stays, ungroomed — grooming is lazy, on pickup.
5. **Merged/closed PRs and Done tickets: untouched.** History stays where it
   happened. (Decision — cheap to revisit; a backfill script can always run
   later.)
6. **Config**: strip the dead vars from `.env` / `.env.example`; write the
   initial watermark = cutover time.
7. **Linear settings** (manual, in-app): delete the unused `conflicting` and
   `ci-red` team labels. In Hyre Ops → Workflows & automations, set
   **"On draft PR open" → No action** (was: In Progress) and **"On PR review
   request or activity" → No action** (was: In review) — both would pull
   tickets out of Todo mid-work under the new model. Leave **"On PR or commit
   merge" → In review** exactly as it is; it already implements the
   merged-ticket move natively. "On PR or commit open → In Progress" can stay:
   loop PRs always open as drafts, so it fires only if it also covers
   draft→ready promotion, and in that case it does the promotion move for us —
   the tick verifies the status either way.
8. Restart the loop; watch two full ticks; then update screenless (§7).

Rollback: statuses are just statuses and both docs are in git — `git revert`
the SKILL.md/gate.sh commit, drag the 13 tickets back to In Progress, restart.
The migrated ticket content is additive and loses nothing either way.

## 9. Sequencing

1. **PR 1 — docs + gate**: SKILL.md rewrite, gate.sh rewrite, `.env.example`.
   Reviewable as one diff because the two files are one design.
2. **PR 2 — screenless**: the ☎️ relay moves to ticket comments + the status
   semantics in its skill. **Must land before or with the cutover**, not
   after: the new gate never reads GitHub comments, so a night with the old
   relay silently drops every call decision — a regression from today.
3. **Migration run** (§8) — a one-night operation, not a commit. Cutover =
   `git pull` in the live skill checkout at the start of this night (mind the
   untracked local `REFACTOR.md`: move it aside first), plus the two
   automation flips (§8.7).
4. First supervised night on the new system; TROUBLESHOOTING.md gains whatever
   that night teaches.

## 10. Review findings, applied

PR 1 was adversarially reviewed (10 confirmed findings); all are fixed in the
branch. The ones that changed the design, not just the code:

- **Merge authorization**: `MERGE_AUTHORS` (default: tier-1 assignee alone)
  gates the "merge" command — the review caught that deleting
  `FEEDBACK_LOGINS` while adding a merge command let anyone with comment
  rights merge to the base branch.
- **Failure freezes state**: a failed or partial comment fetch advances
  nothing — no watermark, no pending prune — and exits `GATE-ERROR`. One
  transient timeout can no longer swallow a comment forever.
- **Catch-up correctness**: the per-probe fetch cap takes the 20 *oldest*
  movers and advances the watermark only past what was actually fetched, so a
  bulk triage or a day of downtime is drained over several probes instead of
  skipped.
- **Ownership filter**: on human-side statuses, only tickets the loop has
  spoken on (a 🌙 comment exists) surface feedback — teammates' own threads
  are not the loop's business. `Todo` tickets surface everything, which is
  what the status means.
- **Scope-exit prune + age floor**: pending entries whose ticket leaves the
  watched statuses are pruned (no immortal wake-storms), and human comments
  older than `LO_FEEDBACK_MAX_AGE_DAYS` (14) never surface — a ticket's
  pre-orchestrator history cannot read as tonight's instructions. `Done` is
  watched, so the merged-then-noted follow-up flow works.
- **Drift is directional**: promoted-PR-dragged-to-Todo is a rework order
  (the invalid label's successor — re-draft, ack, `awaiting-steer`), not an
  error to revert; draft-ticket-dragged-to-In-Progress is repaired once, then
  believed as a human takeover.
- **Anchored markers**: 🌙 is matched at line start (`(?m)^🌙`, legacy
  `<!-- 🌙` accepted), so a human quoting a loop comment reads as a human.

A second review pass (10 more findings, 8 confirmed) hardened the failure
paths; all applied:

- **Any per-ticket parse or fetch failure freezes state** — the empty-body jq
  crash that silently defeated the freeze guard is fixed (guarded `first`,
  exit codes checked), and a failed ticket is never pruned.
- **Graceful Linear degradation**: a dead token no longer blinds the gate to
  GitHub-readable work — the full REGATE/DRAFTS block still prints — and the
  error wakes the model once, then damps for 15 minutes, instead of turning
  `--wait` into a wake-per-minute storm.
- **Full-page refusal**: >100 movers since the watermark (server returns
  newest first, so any advance would skip the oldest forever) refuses to
  advance and wakes the model to decide.
- **Steering allowlist restored**: `LO_FEEDBACK_AUTHORS` (empty = everyone)
  filters who steers; `MERGE_AUTHORS` is resolved by the gate and stamped
  onto each entry as `may_merge`, so the tick has the verdict at runtime.
- **Absolute feedback epoch**: `LO_FEEDBACK_SINCE` (set at cutover) joins the
  rolling 14-day floor — pre-cutover chatter on re-statused tickets cannot
  flood in as instructions on migration night.
- **Durable awaiting-steer**: the human's drag-back rework order is recorded
  as a literal `🌙 Awaiting steer` ticket comment; the WORK_CACHE rebuild
  re-derives the state from it, so a cache rebuild or stop cannot re-promote
  against a standing order.
- **Full drift reconciliation**: the WORK_CACHE rebuild compares every loop
  PR (draft and promoted) against its ticket status — the gate's DRIFT line
  is only the movers fast path; GitHub-born drift is caught within 30 min.
- **Authoritative-PR drift join**: with multiple loop PRs on one ticket
  (superseded draft beside the live one), drift is judged against the newest
  promoted PR, not every branch that mentions the id.
- **Watermark semantics corrected** (§5): it may advance on quiet probes —
  the pending file is the ledger; a lost state dir re-scans the feedback
  window instead of forgetting.
- **`skipped` shape pinned** in the queue schema (objects with `id` + `why`;
  the gate accepts bare strings too).
