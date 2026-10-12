#!/bin/bash
# Watch an orchestrator that runs on a remote Linux server, from a Mac or a Linux
# desktop: one terminal window per screen session (the orchestrator and each
# agent), and a VNC view of the server's Chrome.
#
#   watch-remote.sh [ssh-host]        start watching (default: LO_REMOTE_HOST)
#   watch-remote.sh stop [ssh-host]   close every view
#
# New agents get a window within 10 s; a window closes when its agent ends.
# Windows share their session with screen -x: keys typed there reach that agent,
# so close a window with the window manager (Cmd-W on a Mac), never Ctrl-C.
# Ctrl-C here, or closing this window, closes every view.
# The agents keep running either way.
#
# The browser view needs, on the server, x11vnc serving the display Chrome runs
# on at localhost:5900, and locally its password in LO_REMOTE_VNC_PASSWORD_FILE.
# Without that file the browser view is skipped.
#
# On Linux, LO_REMOTE_TERMINAL picks the terminal: a command that runs the words
# after it, such as "kitty" or "gnome-terminal --". The default is the first one
# installed of gnome-terminal, konsole, xfce4-terminal, kitty, alacritty,
# wezterm, foot, x-terminal-emulator and xterm. The browser view uses TigerVNC's
# vncviewer, else Remmina, else xdg-open.
SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="$SELF/$(basename "$(readlink -f "${BASH_SOURCE[0]}")")"

# What each window runs: "view <ssh-host> <session>". screen draws in the
# terminal's alternate screen, which has no scrollback, so the terminal turns the
# scroll wheel into arrow keys. Dropping the switch to that screen keeps the
# output in the normal screen, where lines that scroll off go to the scrollback.
# screen sends only what is on its screen when a view attaches, so the view
# prints the session's history first, less the window's height of rows that the
# attach draws again. A terminal moves a cleared screen into its scrollback, so
# the view clears that scrollback first, and passes screen's double clear at
# attach as one.
if [ "$1" = view ]; then
  rows=$(stty size 2>/dev/null | cut -d' ' -f1)
  printf '\033[H\033[2J\033[3J'
  ssh "$2" "f=\$(mktemp); screen -S '$3' -X hardcopy -h \$f; sleep 0.3
    awk -v rows='${rows:-0}' '{ l[NR] = \$0 } NF { last = NR } END { for (i = 1; i <= last - rows; i++) printf \"%s%s\", (i > 1 ? \"\\n\" : \"\"), l[i] }' \$f
    rm -f \$f" 2>/dev/null
  ssh -t "$2" screen -U -x "$3" | perl -e '$| = 1;
    while (sysread(STDIN, my $b, 65536)) {
      $b =~ s/\e\[\?(?:1049|1047|47)[hl]//g;
      $b =~ s/(?:\e\[H\e\[2J){2,}/\e[H\e[2J/g;
      syswrite(STDOUT, $b);
    }'
  exit
fi

[ -f "$SELF/.env" ] && set -a && . "$SELF/.env" && set +a
MODE=watch
[ "$1" = stop ] && { MODE=stop; shift; }
HOST="${1:-${LO_REMOTE_HOST:-}}"
[ -n "$HOST" ] || { echo "usage: watch-remote.sh [stop] <ssh-host>   (or set LO_REMOTE_HOST in .env)"; exit 1; }
PORT="${LO_REMOTE_VNC_LOCAL_PORT:-5901}"
PASSFILE="${LO_REMOTE_VNC_PASSWORD_FILE:-}"
TAG="$HOST: "
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/watch-remote"
mkdir -p "$STATE"

port_open() { (exec 3<>"/dev/tcp/localhost/$PORT") 2>/dev/null; }
open_tunnel() {
  port_open || ssh -f -N -o ExitOnForwardFailure=yes -L "$PORT:localhost:5900" "$HOST"
}

if [ "$(uname -s)" = Darwin ]; then
# Windows are known by their tty: the agent's Claude sets its own window title,
# and that replaces any custom title, so a title cannot find a window again.
# One line per window this script opened: "<session> <tty>".
MAP="$STATE/$HOST.ttys"
touch "$MAP"
tty_of() { awk -v n="$1" '$1 == n { print $2 }' "$MAP" | tail -1; }
new_window() {
  osascript - "$1" "$HOST" "$TAG" "$SCRIPT" <<'AS'
on run argv
  set n to item 1 of argv
  set h to item 2 of argv
  set tag to item 3 of argv
  set self to item 4 of argv
  tell application "Terminal"
    -- exec: the shell of the window ends with ssh, so nothing is left running in it
    set t to do script "clear; exec " & quoted form of self & " view " & h & " " & n
    set custom title of t to tag & n
    return tty of t
  end tell
end run
AS
}
open_window() {
  local tty
  tty=$(new_window "$1")
  [ -n "$tty" ] && printf '%s %s\n' "$1" "$tty" >> "$MAP"
  # The orchestrator gets its own colour, so it is easy to find among the agents.
  # Set twice: a shell startup hook (such as termcolor) may repaint a new window.
  [ "$1" = orchestrator ] && { paint_orchestrator; (sleep 2; paint_orchestrator) & }
}
paint_orchestrator() {
  local tty
  tty=$(tty_of orchestrator)
  [ -n "$tty" ] || return 0
  osascript - "$tty" >/dev/null 2>&1 <<'AS'
on run argv
  tell application "Terminal"
    repeat with w in (every window)
      try
        set t to selected tab of w
        if tty of t is (item 1 of argv) then set background color of t to {2500, 17000, 7000}
      end try
    end repeat
  end tell
end run
AS
}
# A window whose ssh has ended runs nothing, so Terminal closes it without asking.
close_finished() {
  local ttys
  ttys=$(awk '{ print $2 }' "$MAP" | tr '\n' ' ')
  [ -n "$ttys" ] || return 0
  osascript - $ttys 2>/dev/null <<'AS' | tr ',' '\n' | sed 's/^ *//' | while read -r tty; do
on run argv
  set closed to {}
  tell application "Terminal"
    set ids to {}
    repeat with w in (every window)
      try
        set t to selected tab of w
        if (argv contains (tty of t)) and (count of processes of t) is 0 then
          set end of ids to id of w
          set end of closed to tty of t
        end if
      end try
    end repeat
    repeat with i in ids
      close (window id i)
    end repeat
  end tell
  return closed
end run
AS
    [ -n "$tty" ] && { grep -v " $tty\$" "$MAP" > "$MAP.tmp"; mv "$MAP.tmp" "$MAP"; }
  done
}
open_browser() {
  open_tunnel
  pbcopy < "$PASSFILE"
  open -a "/System/Applications/Utilities/Screen Sharing.app" "vnc://localhost:$PORT"
  echo "browser: Screen Sharing on localhost:$PORT (the VNC password is on the clipboard)"
}
close_browser() { osascript -e 'tell application "Screen Sharing" to quit' >/dev/null 2>&1; }

else
VIEWER_PID="$STATE/$HOST.viewer.pid"
if [ -n "${LO_REMOTE_TERMINAL:-}" ]; then
  read -r -a TERM_CMD <<< "$LO_REMOTE_TERMINAL"
else
  for t in "gnome-terminal --" "konsole -e" "xfce4-terminal -x" "kitty" "alacritty -e" \
           "wezterm start --" "foot" "x-terminal-emulator -e" "xterm -e"; do
    command -v "${t%% *}" >/dev/null && { read -r -a TERM_CMD <<< "$t"; break; }
  done
fi
[ -n "${TERM_CMD[*]}" ] || { echo "no terminal found; set LO_REMOTE_TERMINAL in .env"; exit 1; }
# The terminal runs ssh as its only command, so the window closes when ssh ends.
# The escape codes set the title, and give the orchestrator its own background
# colour so it is easy to find among the agents; most terminals understand both.
open_window() {
  local bg=""
  [ "$1" = orchestrator ] && bg='\033]11;#0a421b\007'
  setsid "${TERM_CMD[@]}" sh -c "printf '\\033]0;%s\\007$bg' \"\$1\"; exec \"\$4\" view \"\$2\" \"\$3\"" \
    watch-remote "$TAG$1" "$HOST" "$1" "$SCRIPT" >/dev/null 2>&1 < /dev/null &
}
close_finished() { :; }
open_browser() {
  open_tunnel
  local cmd
  if command -v vncviewer >/dev/null && command -v vncpasswd >/dev/null; then
    vncpasswd -f < "$PASSFILE" > "$STATE/$HOST.vncpasswd" && chmod 600 "$STATE/$HOST.vncpasswd"
    cmd=(vncviewer -passwd "$STATE/$HOST.vncpasswd" "localhost::$PORT")
  else
    if command -v wl-copy >/dev/null && [ -n "${WAYLAND_DISPLAY:-}" ]; then wl-copy < "$PASSFILE"
    elif command -v xclip >/dev/null; then xclip -selection clipboard < "$PASSFILE"
    elif command -v xsel >/dev/null; then xsel --clipboard --input < "$PASSFILE"
    fi
    if command -v vncviewer >/dev/null; then cmd=(vncviewer "localhost::$PORT")
    elif command -v remmina >/dev/null; then cmd=(remmina -c "vnc://localhost:$PORT")
    else cmd=(xdg-open "vnc://localhost:$PORT")
    fi
  fi
  setsid "${cmd[@]}" >/dev/null 2>&1 < /dev/null &
  echo $! > "$VIEWER_PID"
  echo "browser: ${cmd[0]} on localhost:$PORT"
}
close_browser() {
  [ -f "$VIEWER_PID" ] && kill "$(cat "$VIEWER_PID")" 2>/dev/null
  rm -f "$VIEWER_PID"
}
fi

sessions() {
  ssh -o ConnectTimeout=10 "$HOST" 'screen -ls' 2>/dev/null \
    | awk '{ if (match($1, /\.(orchestrator|agent-[0-9]+)$/)) print substr($1, RSTART + 1) }' | sort -V
}
stop_views() {
  pkill -f "ssh -t $HOST screen -U -x " 2>/dev/null
  pkill -f "ssh -f -N .*-L $PORT:localhost:5900 $HOST" 2>/dev/null
  close_browser
  # A view ends a moment after its ssh: the filter behind it still has to see the end.
  sleep 1; close_finished; sleep 2; close_finished
  echo "views closed; the agents on $HOST keep running"
}
if [ "$MODE" = stop ]; then stop_views; exit 0; fi
trap 'echo; stop_views; exit 0' INT TERM HUP

[ -n "$PASSFILE" ] && [ -f "$PASSFILE" ] && open_browser
echo "watching $HOST — Ctrl-C closes every view (the agents keep running)"
while :; do
  for n in $(sessions); do
    pgrep -f "ssh -t $HOST screen -U -x $n\$" >/dev/null || { open_window "$n"; echo "$(date +%H:%M) opened $n"; }
  done
  close_finished
  # wait, not a plain sleep: bash runs the trap only once its foreground child ends.
  sleep 10 & wait $!
done
