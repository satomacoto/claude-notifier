#!/bin/sh
# claude-notifier-ctx.sh <claude_pid>
#
# Resolve the terminal context of a running Claude Code process AT CALL TIME,
# from the process tree and live tmux state instead of environment variables.
# Env vars (TERM_PROGRAM / ITERM_SESSION_ID / TMUX) lie: an editor launched
# from a tmux shell hands stale copies of them to every terminal it spawns.
#
# Resolution order:
#   1. The claude pid's controlling tty is matched against live tmux pane
#      ttys. A match proves claude really runs inside that tmux server
#      (a stale $TMUX never passes this check).
#   2. Inside tmux, the terminal is whichever client is attached to that
#      session right now (most recently active one when several are), found
#      by walking the client pid's ancestry to its owning .app bundle.
#   3. Outside tmux, claude's own ancestry is walked to the owning .app.
#
# Prints eval-able assignments:
#   CN_TERMINAL      terminal token (iterm2/terminal/zed/vscode/.../unknown)
#   CN_NAME          display name ("iTerm", "Zed", ...)
#   CN_BUNDLE        app bundle id (dev.zed.Zed, com.googlecode.iterm2, ...)
#   CN_SESSION       ITERM_SESSION_ID for a direct iTerm session, else a
#                    stable per-process key (pid-<pid>); empty inside tmux
#   CN_TMUX_WINID    validated tmux window id (@N), empty outside tmux
#   CN_TMUX_SESSION  tmux session id ($N), empty outside tmux
#   CN_TMUX_SOCKET   tmux server socket path, empty outside tmux
#   CN_TTY           claude's controlling tty (/dev/ttysNNN)
#
# The last successful resolution is cached per pid so a detached tmux
# session (no clients) still reports the terminal it was last seen in.

PID="${1:-$PPID}"
CACHE="/tmp/claude-notifier-ctx-cache-$PID"

CN_TERMINAL=unknown
CN_NAME=""
CN_BUNDLE=""
CN_SESSION=""
CN_TMUX_WINID=""
CN_TMUX_SESSION=""
CN_TMUX_SOCKET=""
CN_TTY=""

T=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
case "$T" in ttys*) CN_TTY="/dev/$T";; esac

# Walk a pid's ancestry to the .app bundle that owns it. Echoes the bundle
# path (e.g. /Applications/Zed.app) or nothing. Helper daemons like
# iTermServer sit between the client and the app but never match
# ".app/Contents/MacOS/", so the walk continues past them.
app_for_pid() {
    p="$1"
    i=0
    while [ "$i" -lt 20 ] && [ "$p" -gt 1 ] 2>/dev/null; do
        line=$(ps -o ppid=,comm= -p "$p" 2>/dev/null) || return 1
        [ -n "$line" ] || return 1
        pp=$(echo "$line" | awk '{print $1}')
        comm=$(echo "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
        case "$comm" in
            *.app/Contents/MacOS/*) echo "${comm%%.app/Contents/MacOS/*}.app"; return 0;;
        esac
        p="$pp"
        i=$((i + 1))
    done
    return 1
}

# 1. Is claude's tty a live tmux pane? Try the socket from $TMUX first
# (claude's own env, correct when claude truly lives in tmux), then the
# default socket. A dead server or a tty that isn't a pane simply fails.
if [ -n "$CN_TTY" ]; then
    CAND=""
    [ -n "$TMUX" ] && CAND="${TMUX%%,*}"
    DEF="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
    [ "$CAND" = "$DEF" ] || CAND="$CAND $DEF"
    for S in $CAND; do
        [ -S "$S" ] || continue
        MATCH=$(tmux -S "$S" list-panes -a -F '#{pane_tty} #{window_id} #{session_id}' 2>/dev/null \
                | awk -v t="$CN_TTY" '$1 == t { print $2, $3; exit }')
        if [ -n "$MATCH" ]; then
            CN_TMUX_WINID=$(echo "$MATCH" | awk '{print $1}')
            CN_TMUX_SESSION=$(echo "$MATCH" | awk '{print $2}')
            CN_TMUX_SOCKET="$S"
            break
        fi
    done
fi

# 2. Pick the pid whose ancestry names the terminal: the freshest attached
# tmux client inside tmux, claude itself outside.
WALK_PID=""
if [ -n "$CN_TMUX_WINID" ]; then
    WALK_PID=$(tmux -S "$CN_TMUX_SOCKET" list-clients -t "$CN_TMUX_SESSION" \
                    -F '#{client_activity} #{client_pid}' 2>/dev/null \
               | sort -rn | awk 'NR==1 {print $2}')
else
    WALK_PID="$PID"
fi

APP=""
[ -n "$WALK_PID" ] && APP=$(app_for_pid "$WALK_PID")

if [ -n "$APP" ]; then
    case "$(basename "$APP")" in
        iTerm.app)                 CN_TERMINAL=iterm2;;
        Terminal.app)              CN_TERMINAL=terminal;;
        Zed.app|Zed\ *.app)        CN_TERMINAL=zed;;
        Ghostty.app)               CN_TERMINAL=ghostty;;
        WezTerm.app)               CN_TERMINAL=wezterm;;
        kitty.app)                 CN_TERMINAL=kitty;;
        Alacritty.app)             CN_TERMINAL=alacritty;;
        Warp.app)                  CN_TERMINAL=warp;;
        Visual\ Studio\ Code.app)  CN_TERMINAL=vscode;;
        *)                         CN_TERMINAL=unknown;;
    esac
    CN_NAME=$(basename "$APP" .app)
    CN_BUNDLE=$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
fi

# 3. Nothing resolved (detached tmux, ancestry walk failed): reuse the last
# known terminal identity, keeping the fresh tmux/tty facts from this run.
if [ -z "$CN_BUNDLE" ] && [ "$CN_TERMINAL" = "unknown" ] && [ -f "$CACHE" ]; then
    OLD_TERMINAL=$(sed -n "s/^CN_TERMINAL='\(.*\)'$/\1/p" "$CACHE")
    OLD_NAME=$(sed -n "s/^CN_NAME='\(.*\)'$/\1/p" "$CACHE")
    OLD_BUNDLE=$(sed -n "s/^CN_BUNDLE='\(.*\)'$/\1/p" "$CACHE")
    [ -n "$OLD_TERMINAL" ] && CN_TERMINAL="$OLD_TERMINAL"
    [ -n "$OLD_NAME" ] && CN_NAME="$OLD_NAME"
    [ -n "$OLD_BUNDLE" ] && CN_BUNDLE="$OLD_BUNDLE"
fi

# 4. Session key for non-tmux sessions (tmux rows key on the window id).
# ITERM_SESSION_ID is only trusted when the ancestry itself says iTerm.
if [ -z "$CN_TMUX_WINID" ]; then
    if [ "$CN_TERMINAL" = "iterm2" ] && [ -n "$ITERM_SESSION_ID" ]; then
        CN_SESSION="$ITERM_SESSION_ID"
    else
        CN_SESSION="pid-$PID"
    fi
fi

emit() {
    for v in CN_TERMINAL CN_NAME CN_BUNDLE CN_SESSION CN_TMUX_WINID CN_TMUX_SESSION CN_TMUX_SOCKET CN_TTY; do
        eval "val=\$$v"
        # single-quote for eval; values never legitimately contain quotes
        printf "%s='%s'\n" "$v" "$(echo "$val" | tr -d "'")"
    done
}

emit
[ "$CN_TERMINAL" != "unknown" ] && emit > "$CACHE" 2>/dev/null
exit 0
