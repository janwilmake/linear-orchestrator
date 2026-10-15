#!/usr/bin/env bash
# lo-usage.sh — estimated plan usage, and the cost ledger per session and project.
#
#   lo-usage.sh [--json]                        windows + this week's spend by project
#   lo-usage.sh tag <session-uuid> <ticket> [--kind <kind>] [--pr <n>]
#
# Reads every Claude Code transcript on this machine (~/.claude/projects), the
# user's own sessions as well as the agents', because they all draw on the same
# plan limits. Each assistant message is priced from its token counts, so a
# session that spans two windows counts in each for what it spent there. The
# price is the API list price: on a subscription it is a measure of load, which
# is what the limits are made of, not of money.
#
# The windows are estimates — the plan's real usage lives on Anthropic's side
# and only /usage shows it:
#   5h    the current 5-hour block: starts at the hour of the first message
#         after the previous block ran out, lasts 5 hours
#   day   the last 24 hours
#   week  since the last LO_USAGE_WEEK_RESET (e.g. "mon 09:00", local time,
#         read it off /usage), or the last 7 days when that is unset
# Budgets: LO_BUDGET_5H (500), LO_BUDGET_DAY (1000), LO_BUDGET_WEEK (7000), USD.
#
# Ledger: ~/.claude/linear-orchestrator/usage/
#   tags.jsonl    one line per spawn, written by `tag`: session → ticket, kind, PR
#   ledger.jsonl  one line per finished session (no message for LO_USAGE_IDLE_MIN,
#                 default 30), written by every run. A session that was resumed
#                 later gets a new line; the last line per session is the one
#                 that counts.
#   tickets.json  cache of ticket → Linear project, looked up through agent-codemode
# A session without a tag is matched to a ticket by its git branch or first
# prompt (LO_PREFIX-123). Spend is grouped by the ticket's Linear project, or
# "(no project)" / "(no ticket)".
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
[ -f "$here/.env" ] && set -a && . "$here/.env" && set +a
dir="$HOME/.claude/linear-orchestrator/usage"
mkdir -p "$dir"

if [ "${1:-}" = tag ]; then
  [ $# -ge 3 ] || { sed -n '3,6p' "$0" >&2; exit 2; }
  session=$2 ticket=$3; shift 3
  kind="" pr=""
  while [ $# -gt 0 ]; do
    case $1 in
      --kind) kind=$2; shift 2 ;;
      --pr) pr=$2; shift 2 ;;
      *) echo "unknown flag $1" >&2; exit 2 ;;
    esac
  done
  [[ $session =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "not a lowercase uuid: $session" >&2; exit 2; }
  python3 -I - "$dir/tags.jsonl" "$session" "$ticket" "$kind" "$pr" <<'PY'
import json, sys, datetime
path, session, ticket, kind, pr = sys.argv[1:6]
row = {"at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "session": session, "ticket": ticket.upper(), "kind": kind or None, "pr": int(pr) if pr else None}
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
PY
  exit 0
fi

json=0
[ "${1:-}" = --json ] && json=1

python3 -I - "$dir" "$json" <<'PY'
import collections, datetime as dt, glob, json, os, re, sys, time

dir, as_json = sys.argv[1], sys.argv[2] == "1"
home = os.path.expanduser("~")
env = os.environ.get
budgets = {"5h": float(env("LO_BUDGET_5H") or 500), "day": float(env("LO_BUDGET_DAY") or 1000),
           "week": float(env("LO_BUDGET_WEEK") or 7000)}
idle = float(env("LO_USAGE_IDLE_MIN") or 30) * 60
prefix = (env("LO_PREFIX") or "").upper()
ticket_re = re.compile(rf"\b({re.escape(prefix)}-\d+)\b", re.I) if prefix else None
agents_dir = os.path.join(home, ".claude", "agents") + os.sep

# USD per million tokens: input, output, cache read. A cache write costs 1.25x
# input for the 5-minute cache and 2x for the 1-hour one. Output includes thinking.
PRICES = {
    "claude-fable-5-1": (10, 50, 0.25), "claude-mythos-5-1": (10, 50, 0.25),
    "claude-fable-5": (10, 50, 1.0), "claude-opus-5-5": (4, 20, 0.20),
    "claude-opus-5": (5, 25, 0.50), "claude-opus-4-8": (5, 25, 0.50),
    "claude-opus-4-7": (5, 25, 0.50), "claude-opus-4-6": (5, 25, 0.50),
    "claude-sonnet-5-5": (2, 10, 0.20), "claude-sonnet-5": (2, 10, 0.20),
    "claude-sonnet-4-6": (3, 15, 0.30), "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1, 5, 0.10),
}
unknown_models = set()

def price(model, u):
    p = PRICES.get(re.sub(r"-\d{8}$", "", model or ""))
    if p is None:
        unknown_models.add(model)
        p = PRICES["claude-opus-5-5"]
    inp, out, read = p
    cc = u.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    w5m = cc.get("ephemeral_5m_input_tokens", u.get("cache_creation_input_tokens", 0) - w1h)
    mult = 2 if u.get("speed") == "fast" else 1
    return mult * (u.get("input_tokens", 0) * inp + u.get("output_tokens", 0) * out
                   + u.get("cache_read_input_tokens", 0) * read
                   + w5m * inp * 1.25 + w1h * inp * 2) / 1e6

def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

now = time.time()
horizon = now - 8 * 86400  # covers the longest window plus a block started before it
msgs = []                  # (epoch, session, usd)
sess = {}

# A session's subagents, workflow agents among them, belong to it and count
# whatever their own age, so the ledger line holds the whole session.
files = []
for f in glob.glob(f"{home}/.claude/projects/*/*.jsonl"):
    if os.path.getmtime(f) >= horizon:
        files.append((f[:-6].rsplit("/", 1)[1], f, False))
        files += [(files[-1][0], g, True) for g in glob.glob(f"{f[:-6]}/subagents/**/agent-*.jsonl", recursive=True)]
for sid, f, sub in files:
    s = sess.setdefault(sid, {"usd": 0.0, "first": None, "last": None, "cwd": None, "branches": collections.Counter(),
                              "prompt": None, "models": collections.defaultdict(lambda: collections.Counter()),
                              "cost_state": None})
    seen = set()
    for line in open(f, "rb"):
        if b'"usage"' not in line and b'"cost-state"' not in line and (s["cwd"] and s["prompt"]):
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        t = r.get("type")
        if not sub:
            s["cwd"] = s["cwd"] or r.get("cwd")
            if r.get("gitBranch") and r["gitBranch"] != "HEAD":
                s["branches"][r["gitBranch"]] += 1
            if t == "user" and s["prompt"] is None and isinstance((r.get("message") or {}).get("content"), str):
                s["prompt"] = r["message"]["content"][:2000]
            if t == "cost-state":
                s["cost_state"] = r
        if t != "assistant":
            continue
        m = r.get("message") or {}
        u, mid, model = m.get("usage"), m.get("id"), m.get("model")
        if not u or not mid or mid in seen or model == "<synthetic>" or "timestamp" not in r:
            continue
        seen.add(mid)
        e, usd = ts(r["timestamp"]), price(model, u)
        msgs.append((e, sid, usd))
        s["usd"] += usd
        s["first"] = e if s["first"] is None else min(s["first"], e)
        s["last"] = e if s["last"] is None else max(s["last"], e)
        c = s["models"][model]
        for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
            c[k] += u.get(k, 0)
sess = {k: v for k, v in sess.items() if v["first"] is not None}
msgs.sort()

# --- attribution ---------------------------------------------------------
def read_jsonl(p):
    try:
        return [json.loads(l) for l in open(p) if l.strip()]
    except FileNotFoundError:
        return []

tags = {r["session"]: r for r in read_jsonl(f"{dir}/tags.jsonl")}

def find_ticket(sid, s):
    ticket = tags.get(sid, {}).get("ticket")
    if not ticket and ticket_re:
        for text in [b for b, _ in s["branches"].most_common()] + [s["prompt"] or ""]:
            hit = ticket_re.search(text)
            if hit:
                return hit.group(1).upper()
    return ticket

# Ticket → Linear project, through the agent-codemode CLI (Claude Code's own
# Linear login, like gate.sh). Cached in tickets.json: a project for a week, "no
# project" for a day, since a ticket is often put in a project after the work.
# A failed lookup is not cached and counts as "(unknown project)" this run.
cache_path = f"{dir}/tickets.json"
try:
    tcache = json.load(open(cache_path))
except (FileNotFoundError, ValueError):
    tcache = {}
tickets = {sid: find_ticket(sid, s) for sid, s in sess.items()}
stale = lambda c: now - c["at"] > (7 * 86400 if c.get("project") else 86400)
todo = sorted({t for t in tickets.values() if t and (t not in tcache or stale(tcache[t]))})
if todo:
    import concurrent.futures, shutil, subprocess
    ac = env("AGENT_CODEMODE") or shutil.which("agent-codemode") or f"{home}/.local/node/bin/agent-codemode"
    def lookup(t):
        try:
            p = subprocess.run([ac, "call", "linear", "get_issue", "--json", json.dumps({"id": t}), "--text"],
                               capture_output=True, text=True, timeout=30)
            issue = json.loads(p.stdout)
            return t, {"project": issue.get("project"), "title": issue.get("title"), "at": now}
        except Exception:
            return t, None
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for t, c in pool.map(lookup, todo):
            if c:
                tcache[t] = c
    with open(cache_path + ".tmp", "w") as f:
        json.dump(tcache, f, indent=1, sort_keys=True)
    os.replace(cache_path + ".tmp", cache_path)

def attribute(sid, s):
    tag, ticket = tags.get(sid, {}), tickets[sid]
    if not ticket:
        project = "(no ticket)"
    elif ticket not in tcache:
        project = "(unknown project)"
    else:
        project = tcache[ticket].get("project") or "(no project)"
    agent = (s["cwd"] or "").startswith(agents_dir)
    return {"ticket": ticket, "project": project, "kind": tag.get("kind"), "pr": tag.get("pr"),
            "source": "agent" if agent else "interactive", "cwd": s["cwd"]}

# --- windows -------------------------------------------------------------
def block_start():
    start = None
    for e, _, _ in msgs:
        if start is None or e >= start + 5 * 3600:
            start = e - e % 3600
    return start if start is not None and now < start + 5 * 3600 else None

def week_start():
    spec = (env("LO_USAGE_WEEK_RESET") or "").strip().lower()
    hit = re.fullmatch(r"(mon|tue|wed|thu|fri|sat|sun)\w*\s+(\d{1,2}):(\d{2})", spec)
    if not hit:
        return now - 7 * 86400, None
    day = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].index(hit.group(1))
    local = dt.datetime.now().astimezone()
    reset = local.replace(hour=int(hit.group(2)), minute=int(hit.group(3)), second=0, microsecond=0)
    reset -= dt.timedelta(days=(local.weekday() - day) % 7)
    if reset > local:
        reset -= dt.timedelta(days=7)
    return reset.timestamp(), reset.timestamp() + 7 * 86400

b5 = block_start()
wk, wk_reset = week_start()
starts = {"5h": b5, "day": now - 86400, "week": wk}
resets = {"5h": b5 + 5 * 3600 if b5 else None, "day": None, "week": wk_reset}
windows = {}
for name, start in starts.items():
    spent = sum(usd for e, _, usd in msgs if start is not None and e >= start)
    windows[name] = {"usd": round(spent, 2), "budget": budgets[name], "pct": round(100 * spent / budgets[name], 1),
                     "since": dt.datetime.fromtimestamp(start).astimezone().isoformat(timespec="minutes") if start else None,
                     "resets": dt.datetime.fromtimestamp(resets[name]).astimezone().isoformat(timespec="minutes") if resets[name] else None}

attr = {sid: attribute(sid, s) for sid, s in sess.items()}
by_project = collections.Counter()
for e, sid, usd in msgs:
    if e >= wk:
        by_project[attr[sid]["project"]] += usd

# --- ledger --------------------------------------------------------------
ledger_path = f"{dir}/ledger.jsonl"
settled = {r["session"]: r.get("last") for r in read_jsonl(ledger_path)}
iso = lambda e: dt.datetime.fromtimestamp(e, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
new = []
for sid, s in sorted(sess.items(), key=lambda kv: kv[1]["last"]):
    if now - s["last"] < idle or settled.get(sid) == iso(s["last"]):
        continue
    cs = s["cost_state"] or {}
    new.append({"session": sid, **attr[sid], "start": iso(s["first"]), "last": iso(s["last"]),
                "usd": round(s["usd"], 4), "cost_state_usd": cs.get("totalCostUSD"),
                "wall_s": round(s["last"] - s["first"]),
                "api_s": round(cs["totalAPIDuration"] / 1000) if "totalAPIDuration" in cs else None,
                "tool_s": round(cs["totalToolDuration"] / 1000) if "totalToolDuration" in cs else None,
                "lines_added": cs.get("totalLinesAdded"), "lines_removed": cs.get("totalLinesRemoved"),
                "tokens": {m: dict(c) for m, c in s["models"].items()}})
if new:
    with open(ledger_path, "a") as f:
        for row in new:
            f.write(json.dumps(row) + "\n")

# --- output --------------------------------------------------------------
running = sum(1 for s in sess.values() if now - s["last"] < idle)
out = {"windows": windows, "week_by_project": {k: round(v, 2) for k, v in by_project.most_common()},
       "sessions_active": running, "ledger_new": len(new),
       "unknown_models": sorted(m for m in unknown_models if m)}
if as_json:
    print(json.dumps(out, indent=2))
    sys.exit(0)
hm = lambda iso_s: dt.datetime.fromisoformat(iso_s).strftime("%a %H:%M")
for name, w in windows.items():
    tail = f"   resets {hm(w['resets'])}" if w["resets"] else ("   no block running" if name == "5h" and not w["since"] else "")
    print(f"{name:<5} ${w['usd']:>8,.0f} / ${w['budget']:,.0f}  {w['pct']:>5.1f}%{tail}")
print("week by project: " + " · ".join(f"{k} ${v:,.0f}" for k, v in by_project.most_common(8)))
print(f"{running} session(s) active · {len(new)} settled into the ledger")
if out["unknown_models"]:
    print("unpriced models (counted at Opus 5.5 prices): " + ", ".join(out["unknown_models"]))
PY
