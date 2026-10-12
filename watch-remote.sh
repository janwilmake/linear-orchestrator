#!/bin/bash
# Watch an orchestrator that runs on a remote Linux server, from a Mac: one
# Terminal window per screen session (the orchestrator and each agent), and
# Screen Sharing on the server's Chrome.
#
#   watch-remote.sh [ssh-host]        start watching (default: LO_REMOTE_HOST)
#   watch-remote.sh stop [ssh-host]   close every view
#
# New agents get a window within 10 s; a window closes when its agent ends.
# Windows share their session with screen -x: keys typed there reach that agent,
# so close a window with Cmd-W, never Ctrl-C. Ctrl-C here, or closing this
# window, closes every view.
# The agents keep running either way.
#
# The browser view needs, on the server, x11vnc serving the display Chrome runs
# on at localhost:5900, and on the Mac its password in LO_REMOTE_VNC_PASSWORD_FILE.
# Without that file the browser view is skipped.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SELF/.env" ] && set -a && . "$SELF/.env" && set +a
MODE=watch
[ "$1" = stop ] && { MODE=stop; shift; }
HOST="${1:-${LO_REMOTE_HOST:-}}"
[ -n "$HOST" ] || { echo "usage: watch-remote.sh [stop] <ssh-host>   (or set LO_REMOTE_HOST in .env)"; exit 1; }
PORT="${LO_REMOTE_VNC_LOCAL_PORT:-5901}"
PASSFILE="${LO_REMOTE_VNC_PASSWORD_FILE:-}"
TAG="$HOST: "

open_window() {
  osascript - "$1" "$HOST" "$TAG" >/dev/null <<'AS'
on run argv
  set n to item 1 of argv
  set h to item 2 of argv
  set tag to item 3 of argv
  tell application "Terminal"
    -- exec: the window's shell ends with ssh, so nothing is left running in it
    set t to do script "clear; exec ssh -t " & h & " screen -U -x " & n
    set custom title of t to tag & n
  end tell
end run
AS
  # The orchestrator gets its own colour, so it is easy to find among the agents.
  # Set twice: a shell startup hook (such as termcolor) may repaint a new window.
  [ "$1" = orchestrator ] && { paint_orchestrator; (sleep 2; paint_orchestrator) & }
}
paint_orchestrator() {
  osascript - "${TAG}orchestrator" >/dev/null 2>&1 <<'AS'
on run argv
  tell application "Terminal"
    repeat with w in (every window)
      try
        set t to selected tab of w
        if custom title of t is (item 1 of argv) then set background color of t to {2500, 17000, 7000}
      end try
    end repeat
  end tell
end run
AS
}
# A window whose ssh has ended runs nothing, so Terminal closes it without asking.
close_finished() {
  osascript - "$TAG" >/dev/null 2>&1 <<'AS'
on run argv
  set tag to item 1 of argv
  tell application "Terminal"
    set ids to {}
    repeat with w in (every window)
      try
        set t to selected tab of w
        if custom title of t starts with tag and (count of processes of t) is 0 then set end of ids to id of w
      end try
    end repeat
    repeat with i in ids
      close (window id i)
    end repeat
  end tell
end run
AS
}
sessions() {
  ssh -o ConnectTimeout=10 "$HOST" 'screen -ls' 2>/dev/null \
    | awk '{ if (match($1, /\.(orchestrator|agent-[0-9]+)$/)) print substr($1, RSTART + 1) }' | sort -V
}
stop_views() {
  pkill -f "ssh -t $HOST screen -U -x " 2>/dev/null
  pkill -f "ssh -f -N .*-L $PORT:localhost:5900 $HOST" 2>/dev/null
  osascript -e 'tell application "Screen Sharing" to quit' >/dev/null 2>&1
  sleep 1
  close_finished
  echo "views closed; the agents on $HOST keep running"
}
if [ "$MODE" = stop ]; then stop_views; exit 0; fi
trap 'echo; stop_views; exit 0' INT TERM HUP

if [ -n "$PASSFILE" ] && [ -f "$PASSFILE" ]; then
  nc -z localhost "$PORT" 2>/dev/null \
    || ssh -f -N -o ExitOnForwardFailure=yes -L "$PORT:localhost:5900" "$HOST"
  pbcopy < "$PASSFILE"
  open -a "/System/Applications/Utilities/Screen Sharing.app" "vnc://localhost:$PORT"
  echo "browser: Screen Sharing on localhost:$PORT (the VNC password is on the clipboard)"
fi
echo "watching $HOST — Ctrl-C closes every view (the agents keep running)"
while :; do
  for n in $(sessions); do
    pgrep -qf "ssh -t $HOST screen -U -x $n\$" || { open_window "$n"; echo "$(date +%H:%M) opened $n"; }
  done
  close_finished
  sleep 10
done
