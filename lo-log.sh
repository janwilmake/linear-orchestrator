#!/usr/bin/env bash
# lo-log.sh — append one entry to the loop's single log comment on a PR.
#
# Every PR the loop touches carries ONE comment from the loop, a timeline of
# collapsed entries, oldest at the top and newest at the bottom. This script is
# the only writer, so every agent writes the same shape.
#
#   lo-log.sh <PR#> <kind> "<one-line summary>" <detail-file | -> [--ack <comment-id>]
#
#   kind      review | fix | merge | ci | rework | human | adopt-review | split | restack | note
#   summary   what the collapsed line says, e.g. "Review: 0 blockers, 3 follow-ups"
#   detail    markdown shown when the entry is expanded ("-" reads stdin)
#   --ack     the id of the human comment this entry answers (kind human)
#   --dry-run print the new comment body and write nothing
#
# The entry carries a hidden marker the gate and the tick read:
#   <!-- 🌙 lo:<owner> entry kind=<kind> at=<UTC ISO> sha=<head sha> [ack:<id>] -->
# `ack:<id>` is what tells the gate a human comment is answered, and
# `lo:<owner> adopt-review` is what tells it an adopted PR was reviewed.
#
# The repo is the one of the current checkout; set LO_LOG_REPO=owner/name to override.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
[ -f "$here/.env" ] && set -a && . "$here/.env" && set +a
owner="${LO_OWNER:-}"
tag="🌙${owner:+ lo:$owner}"

[ $# -ge 4 ] || { sed -n '4,20p' "$0" >&2; exit 2; }
pr=$1 kind=$2 summary=$3 detail_src=$4; shift 4
ack="" dry=0
while [ $# -gt 0 ]; do
  case $1 in
    --ack) ack=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
case $kind in review|fix|merge|ci|rework|human|adopt-review|split|restack|note) ;; *) echo "unknown kind $kind" >&2; exit 2 ;; esac
[ "$kind" = human ] && [ -z "$ack" ] && { echo "kind human needs --ack <comment-id>" >&2; exit 2; }
case $summary in *$'\n'*) echo "summary must be one line" >&2; exit 2 ;; esac

if [ "$detail_src" = - ]; then detail=$(cat); else detail=$(cat "$detail_src"); fi
repo="${LO_LOG_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
sha=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid | cut -c1-7)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$detail" > "$tmp/detail"
# Re-read the comment right before the write, so an entry another writer added
# a moment ago is kept.
gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate \
  --jq "[ .[] | select(.body | contains(\"<!-- $tag log -->\")) | {id, body} ] | first // empty" 2>/dev/null | head -1 > "$tmp/log.json" || true

python3 - "$tmp" "$tag" "$kind" "$summary" "$sha" "$ack" <<'PY'
import json, os, re, sys, datetime, zoneinfo
tmp, tag, kind, summary, sha, ack = sys.argv[1:7]
detail = open(os.path.join(tmp, "detail")).read().strip()
raw = open(os.path.join(tmp, "log.json")).read().strip()
old = json.loads(raw) if raw else None
now = datetime.datetime.now(datetime.timezone.utc)
local = now.astimezone(zoneinfo.ZoneInfo("Europe/Amsterdam")).strftime("%Y-%m-%d %H:%M")
marker = f"<!-- {tag} entry kind={kind} at={now.strftime('%Y-%m-%dT%H:%M:%SZ')} sha={sha}"
if ack:
    marker += f" ack:{ack}"
if kind == "adopt-review":
    marker += f" {tag} adopt-review"
marker += " -->"
line = f"<b>{local} - 🧍 Request (Human Input) - {summary}</b>" if kind == "human" else f"{local} · {summary}"
entry = f"{marker}\n<details>\n\n<summary>{line}</summary>\n\n{detail}\n\n</details>\n"
head = f"<!-- {tag} log -->\n**linear-orchestrator log** — newest at the bottom. Expand a line for the details.\n\n"
body = (old["body"].rstrip() + "\n\n" + entry) if old else head + entry
# GitHub caps a comment at 65,536 characters. Shrink the oldest entries to
# their summary line until the body fits.
LIMIT = 60000
if len(body) > LIMIT:
    parts = re.split(r"(?=<!-- " + re.escape(tag) + r" entry )", body)
    top, entries = parts[0], parts[1:]
    for i, e in enumerate(entries[:-1]):
        if len(top + "".join(entries)) <= LIMIT:
            break
        entries[i] = re.sub(r"(</summary>\n\n).*?(\n\n</details>)", r"\1(trimmed to fit the comment limit)\2", e, count=1, flags=re.S)
    body = top + "".join(entries)
open(os.path.join(tmp, "body"), "w").write(body)
open(os.path.join(tmp, "id"), "w").write(str(old["id"]) if old else "")
PY

if [ "$dry" = 1 ]; then cat "$tmp/body"; exit 0; fi
id=$(cat "$tmp/id")
if [ -n "$id" ]; then
  gh api -X PATCH "repos/$repo/issues/comments/$id" -F body=@"$tmp/body" --jq .html_url
else
  gh api -X POST "repos/$repo/issues/$pr/comments" -F body=@"$tmp/body" --jq .html_url
fi
