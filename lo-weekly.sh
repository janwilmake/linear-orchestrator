#!/usr/bin/env bash
# lo-weekly.sh — the weekly report: plan usage per project, PRs merged into the
# base branch, and the lines they changed, for the week that ended at the last
# LO_USAGE_WEEK_RESET.
#
#   lo-weekly.sh          prints the report (Markdown) when one is due, else nothing
#   lo-weekly.sh --done   records that the due report was posted
#   lo-weekly.sh --force  prints the report for the last week that ended, due or not
#
# Off until both LO_USAGE_WEEK_RESET and LO_WEEKLY_CHANNEL are set. A report is
# due once per week, from the reset on. One that is more than 3 days late is
# recorded as skipped instead of posted: a stale week helps nobody.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/.env" ] && set -a && . "$here/.env" && set +a
[ -n "${LO_USAGE_WEEK_RESET:-}" ] && [ -n "${LO_WEEKLY_CHANNEL:-}" ] || exit 0
dir="$HOME/.claude/watchloop"
mkdir -p "$dir"
usage=$("$here/lo-usage.sh" --json)

python3 -I - "$dir/${LO_PREFIX:-LO}-weekly.json" "${1:-}" "${LO_REPO:-$PWD}" "${LO_BASE:-dev}" "$usage" <<'PY'
import datetime as dt, json, subprocess, sys

state_path, mode, repo, base, usage = sys.argv[1:6]
lw = json.loads(usage).get("last_week")
if not lw:
    sys.exit(0)
try:
    state = json.load(open(state_path))
except (FileNotFoundError, ValueError):
    state = {}

def record(**kw):
    state.update(kw)
    with open(state_path + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    import os
    os.replace(state_path + ".tmp", state_path)

until = dt.datetime.fromisoformat(lw["until"])
since = dt.datetime.fromisoformat(lw["since"])
if mode == "--done":
    record(posted_for=lw["until"], posted_at=dt.datetime.now().astimezone().isoformat(timespec="minutes"))
    sys.exit(0)
if mode != "--force":
    if state.get("posted_for") == lw["until"]:
        sys.exit(0)
    if dt.datetime.now().astimezone() - until > dt.timedelta(days=3):
        record(posted_for=lw["until"], skipped="more than 3 days late")
        sys.exit(0)

q = f"merged:{since.isoformat()}..{until.isoformat()}"
p = subprocess.run(["gh", "pr", "list", "--state", "merged", "--base", base, "--search", q,
                    "--json", "number,additions,deletions,body", "--limit", "1000"],
                   cwd=repo, capture_output=True, text=True)
if p.returncode != 0:
    print(f"lo-weekly: gh failed: {p.stderr.strip()}", file=sys.stderr)
    sys.exit(1)
prs = json.loads(p.stdout)
added = sum(x["additions"] for x in prs)
removed = sum(x["deletions"] for x in prs)
net = added - removed
by_loop = sum(1 for x in prs if "🌙 lo:" in (x.get("body") or ""))

span = f"{since.strftime('%a %-d %b %H:%M')} → {until.strftime('%a %-d %b %H:%M')}"
lines = [f"**Weekly report · {span}**", ""]
lines.append(f"- **Plan usage:** ${lw['usd']:,.0f} of the ${lw['budget']:,.0f} week budget ({lw['pct']:.0f}%), at API list prices.")
for name, usd in list(lw["by_project"].items())[:10]:
    lines.append(f"  - {name} · ${usd:,.0f}")
lines.append(f"- **PRs merged into `{base}`:** {len(prs)} ({by_loop} opened by the loop).")
lines.append(f"- **Lines:** +{added:,} added · −{removed:,} removed · net {'+' if net >= 0 else '−'}{abs(net):,}.")
print("\n".join(lines))
PY
