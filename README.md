# claude-notifier

macOS native notification manager for Claude Code, with terminal-aware click-to-focus.

Runs as a resident app with a notification inbox window and a Dock icon. Claude Code hooks send notifications via a custom URL scheme, with no process spawning per notification. Notifications collect in a scrollable list; click one to jump to the terminal that sent it.

## Prerequisites

- **macOS** (uses NSUserNotificationCenter)
- **Swift** compiler (`swiftc`) — included with Xcode Command Line Tools
- **jq** — for parsing hook input (`brew install jq`)
- **python3** — for URL encoding in hook command
- **iTerm2** with Python API enabled (Preferences > General > Magic > Enable Python API) — for tab focus

## macOS Permissions

1. **Privacy & Security > App Management** — Allow `claude-notifier.app`
2. **Notifications** — Allow notifications from `claude-notifier` (System Settings > Notifications)

## Build & Run

```bash
./build.sh                          # compiles → build/claude-notifier.app
open build/claude-notifier.app      # first launch registers the URL scheme
```

Run the app from `build/claude-notifier.app` directly. Do **not** also copy it to
`~/Applications/`: the same bundle id registered at two paths makes macOS treat them as separate
apps, so a notification can launch a second instance while one is already running.

If you previously installed a copy, remove and unregister it so the URL scheme resolves to a
single handler:

```bash
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -u ~/Applications/claude-notifier.app
rm -rf ~/Applications/claude-notifier.app
"$lsregister" -f "$PWD/build/claude-notifier.app"
```

## Usage

Send notifications via URL scheme:

```bash
# Basic
open -g "claude-notifier://notify?message=Hello"

# With title and sound
open -g "claude-notifier://notify?title=MyProject&message=Ready&sound=Ping"

# With iTerm2 tab focus (non-tmux)
open -g "claude-notifier://notify?title=MyProject&message=Ready&terminal=iterm2&session=SESSION_ID"

# With iTerm2 tab focus (tmux integration)
open -g "claude-notifier://notify?title=MyProject&message=Ready&terminal=iterm2&tmux_window_id=@4"

# Quit the app
open "claude-notifier://quit"
```

### URL Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `title` | No | `Claude Code` | Notification title |
| `message` | No | (empty) | Notification body |
| `sound` | No | User preference | Sound name (e.g. `Ping`, `Glass`, `Submarine`) |
| `terminal` | No | `unknown` | Terminal type: `iterm2`, `vscode`, `terminal`, `ghostty`, `wezterm`, `kitty`, `alacritty`, `warp`, `zed` |
| `terminal_name` | No | Built-in table | Display name override (e.g. `Zed`); lets the hook label apps not in the built-in table |
| `bundle` | No | Built-in table | App bundle id override (e.g. `dev.zed.Zed`); lets clicks focus apps not in the built-in table |
| `session` | No | None | iTerm2 session ID (`ITERM_SESSION_ID`) for non-tmux tab focus; the ctx-script hook sends a stable `pid-<pid>` key for non-iTerm sessions |
| `tmux_window_id` | No | None | tmux window ID (e.g. `@4`) for tmux integration tab focus |
| `tmux_socket` | No | None | tmux server socket path; with `tmux_session`, lets a click re-resolve which terminal is attached right now |
| `tmux_session` | No | None | tmux session ID (e.g. `$0`); see `tmux_socket` |
| `workdir` | No | None | Project root path; a click on a Zed notification focuses that workspace's window via the `zed` CLI |
| `status` | No | `review` | Status dot color: `running`, `waiting`, `review`, `done`, `failed`, `message` |
| `source` | No | None | Optional tag shown in the row's meta line (e.g. `recap`, `title`, `alert`) to mark which message source was used |
| `tty` | No | None | Controlling tty (e.g. `/dev/ttys004`) for Terminal.app tab-level focus |
| `tool` | No | None | Tool that triggered the prompt (e.g. `Bash`); shown in the row's meta line |
| `thinking` | No | None | Live "Claude is working" state: `start` shows a silent spinner row for the tab (never banners/sounds, not counted as unread); `stop` stops the spinner and keeps the row as quiet, clickable history (a real notification that arrived mid-turn is left as-is) |

All values must be URL-encoded. Use `open -g` to avoid stealing focus from the current app.

## Claude Code Hooks Integration

First install the shared context-resolver script (the in-app **Install Claude Code Hooks…**
menu item does this for you):

```bash
mkdir -p ~/.claude/hooks
cp hooks/claude-notifier-ctx.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/claude-notifier-ctx.sh
```

The script resolves which terminal a Claude Code process belongs to **at event time**, from
the process tree and live tmux state instead of environment variables (which go stale: an
editor launched from a tmux shell hands stale `$TMUX` / `$ITERM_SESSION_ID` copies to every
terminal it spawns). Inside tmux it asks the tmux server which client is attached right now,
so re-attaching a session from a different terminal is reflected in the next notification;
outside tmux it walks the process ancestry to the owning app (iTerm2, Zed, Terminal, …).

Then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "command": "~/.claude/hooks/claude-notifier-ctx.sh $PPID >/dev/null 2>&1; exit 0",
            "type": "command"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "command": "IN=$(cat) && MSG=$(echo \"$IN\" | jq -r '.message // \"Claude Code is ready\"') && NTYPE=$(echo \"$IN\" | jq -r '.notification_type // \"\"') && STATUS=$(case \"$NTYPE\" in (permission_prompt) echo review;; (idle_prompt) echo waiting;; (auth_success) echo done;; (*) echo review;; esac) && TRANSCRIPT=$(echo \"$IN\" | jq -r '.transcript_path // \"\"') && AWAY=$(cat \"$TRANSCRIPT\" 2>/dev/null | jq -rs '([.[] | select(.type==\"system\" and .subtype==\"away_summary\") | .content] | last // \"\") | .[0:1000]' 2>/dev/null | tr '\\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') && TITLE=$(cat \"$TRANSCRIPT\" 2>/dev/null | jq -rs '[.[] | select(.type==\"ai-title\") | .aiTitle] | last // \"\"' 2>/dev/null | tr '\\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') && SRC=alert && if [ -n \"$AWAY\" ]; then MSG=\"$AWAY\"; SRC=recap; elif [ -n \"$TITLE\" ]; then MSG=\"$TITLE\"; SRC=title; fi; eval \"$(~/.claude/hooks/claude-notifier-ctx.sh $PPID 2>/dev/null)\"; TOP=$(git -C \"$PWD\" rev-parse --show-toplevel 2>/dev/null || echo \"$PWD\"); PROJECT=$(basename \"$TOP\"); ENC(){ python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$1\"; }; open -g \"claude-notifier://notify?title=$(ENC \"$PROJECT\")&message=$(ENC \"$MSG\")&terminal=$CN_TERMINAL&terminal_name=$(ENC \"$CN_NAME\")&bundle=$(ENC \"$CN_BUNDLE\")&session=$(ENC \"$CN_SESSION\")&tmux_window_id=$(ENC \"$CN_TMUX_WINID\")&tmux_socket=$(ENC \"$CN_TMUX_SOCKET\")&tmux_session=$(ENC \"$CN_TMUX_SESSION\")&tty=$(ENC \"$CN_TTY\")&workdir=$(ENC \"$TOP\")&status=$STATUS&source=$SRC\"",
            "type": "command"
          }
        ],
        "matcher": ""
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "command": "[ -f /tmp/claude-notifier-remote-approvals ] || exit 0; IN=$(cat); TOOL=$(echo \"$IN\" | jq -r '.tool_name // \"Bash\"'); CMD=$(echo \"$IN\" | jq -r '.tool_input.command // .tool_input.file_path // \"\"' | tr '\\n' ' ' | cut -c1-200); REQ=\"$PPID-$$-$(date +%s)\"; eval \"$(~/.claude/hooks/claude-notifier-ctx.sh $PPID 2>/dev/null)\"; TOP=$(git -C \"$PWD\" rev-parse --show-toplevel 2>/dev/null || echo \"$PWD\"); PROJECT=$(basename \"$TOP\"); ENC(){ python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$1\"; }; rm -f \"/tmp/claude-notifier-decision-$REQ.json\"; open -g \"claude-notifier://notify?title=$(ENC \"$PROJECT\")&message=$(ENC \"$TOOL: $CMD\")&terminal=$CN_TERMINAL&terminal_name=$(ENC \"$CN_NAME\")&bundle=$(ENC \"$CN_BUNDLE\")&session=$(ENC \"$CN_SESSION\")&tmux_window_id=$(ENC \"$CN_TMUX_WINID\")&tmux_socket=$(ENC \"$CN_TMUX_SOCKET\")&tmux_session=$(ENC \"$CN_TMUX_SESSION\")&tty=$(ENC \"$CN_TTY\")&workdir=$(ENC \"$TOP\")&status=review&tool=$(ENC \"$TOOL\")&decision=$REQ\"; D=\"\"; for i in $(seq 1 120); do if [ -f \"/tmp/claude-notifier-decision-$REQ.json\" ]; then D=$(jq -r '.decision // \"\"' \"/tmp/claude-notifier-decision-$REQ.json\" 2>/dev/null); rm -f \"/tmp/claude-notifier-decision-$REQ.json\"; break; fi; sleep 0.5; done; [ \"$D\" = \"allow\" ] && printf '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"Approved in claude-notifier\"}}'; [ \"$D\" = \"deny\" ] && printf '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Denied in claude-notifier\"}}'; exit 0",
            "type": "command"
          }
        ],
        "matcher": "Bash"
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "command": "eval \"$(~/.claude/hooks/claude-notifier-ctx.sh $PPID 2>/dev/null)\"; TOP=$(git -C \"$PWD\" rev-parse --show-toplevel 2>/dev/null || echo \"$PWD\"); PROJECT=$(basename \"$TOP\"); ENC(){ python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$1\"; }; open -g \"claude-notifier://notify?title=$(ENC \"$PROJECT\")&terminal=$CN_TERMINAL&terminal_name=$(ENC \"$CN_NAME\")&bundle=$(ENC \"$CN_BUNDLE\")&session=$(ENC \"$CN_SESSION\")&tmux_window_id=$(ENC \"$CN_TMUX_WINID\")&tmux_socket=$(ENC \"$CN_TMUX_SOCKET\")&tmux_session=$(ENC \"$CN_TMUX_SESSION\")&tty=$(ENC \"$CN_TTY\")&workdir=$(ENC \"$TOP\")&status=running&thinking=start\"",
            "type": "command"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "command": "eval \"$(~/.claude/hooks/claude-notifier-ctx.sh $PPID 2>/dev/null)\"; ENC(){ python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$1\"; }; open -g \"claude-notifier://notify?session=$(ENC \"$CN_SESSION\")&tmux_window_id=$(ENC \"$CN_TMUX_WINID\")&thinking=stop\"",
            "type": "command"
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "command": "eval \"$(~/.claude/hooks/claude-notifier-ctx.sh $PPID 2>/dev/null)\"; ENC(){ python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$1\"; }; open -g \"claude-notifier://notify?session=$(ENC \"$CN_SESSION\")&tmux_window_id=$(ENC \"$CN_TMUX_WINID\")&thinking=stop\"",
            "type": "command"
          }
        ]
      }
    ]
  }
}
```

The `UserPromptSubmit` / `Stop` / `StopFailure` hooks drive the live **thinking** indicator: a
prompt submission lights a silent spinner row for that tab, and the end of the turn clears it.
`StopFailure` (and the `idle_prompt` Notification) recover the state if a turn is interrupted,
since `Stop` does not fire on Esc.

## Notification Inbox

The main window is a scrollable inbox of recent notifications. Each row shows a left indicator,
the project name, the terminal and tab shortcut, a relative time, and the message.

- **Click a row** to focus the terminal that sent it (the row is then marked read).
- **Press ×** on a row to dismiss just that one, or **Clear read** in the header to clear the
  acted-on history (keeps pending and in-progress rows). **Clear All** is in the Notifications menu.
- **Left indicator.** Normally an SF Symbol icon for the notification's sound (so the same
  project shows the same icon when Per-Project Sound is on), tinted by the status color. While
  Claude is mid-turn the indicator is a small spinner (see **Live thinking indicator** below).
  The color reflects why the notification fired: the provided hook maps Claude Code's
  `notification_type` to `status=` (permission prompt = orange `review`, idle/input prompt =
  gray `waiting`, successful auth = green `done`).
- **Live thinking indicator.** With the `UserPromptSubmit` / `Stop` hooks installed, a tab shows
  a silent spinner row the moment you submit a prompt; when the turn ends the spinner stops and
  the row stays as quiet, clickable history (so you can still jump to that tab). You can see at a
  glance which tabs are still working vs done. Thinking rows never banner, sound, or count toward
  the unread badge, and clicking one focuses its tab without dismissing it.
- **The message is a recap.** Instead of a generic "Claude is waiting for your input", the
  provided hook reads the session transcript (`transcript_path`) and uses Claude Code's own
  session recap (the latest `away_summary` entry) as the notification text, so you see a
  concise summary of where things stand. When no recap exists yet, it falls back to the
  short auto-generated conversation title (`ai-title`), and finally to the plain event
  message (the "waiting"/"permission" notice). The recap itself is only generated by Claude
  Code after the terminal has been unfocused for ~5 minutes, so quick turnarounds use a
  fallback. The row's meta line is tagged with which source was used (`recap`, `title`, or
  `alert`) so you can tell a real recap from a fallback at a glance.
- **Repeated notifications stack on one row.** If the same tab notifies again, its row floats
  back to the top with the latest message and shows a **×N** badge counting how many times it
  has pinged you, so you can tell it fired more than once.
- Notifications stay in the list until you act on them or dismiss them; acted-on ones remain
  as dimmed history. Switching to a notification's iTerm2 tab while iTerm2 is frontmost marks it
  read automatically.
- **Visual arrival cue (no sound needed):** the Dock icon and the menu-bar bell both show an
  unread-count badge that increments as notifications arrive and clears as you read them. The
  native banner (see **Banner modes** above) is an additional cue. Enable **Always on Top** to
  keep the inbox window floating above other apps so new rows are always in view.
- **Closing the window keeps the app running** in the background so it still receives
  notifications. Click the Dock icon to reopen the window. Quit with Cmd+Q.
- Launched at login, the app starts in the background (Dock icon and badge only) and does not
  steal focus; the window opens when you launch it manually or click the Dock icon.

Settings live in the menu bar (and the in-window gear button): **Sound**, **Per-Project
Sound** (auto-assign a distinct sound per project), **Per-Status Sound** (a distinct sound per
status, so a failure sounds different from a completion), **Banner** (how the native macOS
banner behaves: Off, Auto-dismiss, or Keep in Notification Center), **Do Not Disturb** (pause
banners/sounds for a while, or a nightly 10 PM to 8 AM quiet-hours window), **Re-alert Unread**
(re-alert once for an unread high-importance item left untouched), **Compact Rows**, **Always on
Top** (float the window above other apps), **Launch at Login**, **Webhook…** (forward
notifications to an HTTPS endpoint), and **Remote Approvals (Bash)**. There is also a one-command
**Install Claude Code Hooks…** that writes the hook config for you.

### Inbox controls

A search field, a status filter, and a **sort selector** narrow and order the list. Sort options:
**Recent** (default, newest first), **Project** (grouped by project name, then by tab order, then
recency), and **Tab** (the iTerm tab order ⌘N; rows without a resolved shortcut go last). The
choice is remembered. Keyboard navigation works when the list has focus: **↑/↓** select, **Return**
opens the selected notification (focuses its terminal), and **Delete** dismisses it. A small dot in
the header shows the iTerm2 focus-connection health (only when iTerm2 is in use).

### One-command setup

**Install Claude Code Hooks…** merges the SessionStart, Notification, and (no-op until enabled)
approval hooks into `~/.claude/settings.json`. It saves a timestamped backup first, shows a
preview to confirm, replaces any prior claude-notifier entries (so it is safe to re-run), and
refuses to touch a settings file that is not a JSON object.

### Remote approvals (Bash, optional)

Turn on **Remote Approvals (Bash)** before you step away. Bash permission prompts then appear in
the inbox with **Approve** / **Deny** buttons, so you can answer without returning to the
terminal. It is a no-op when off (the `PreToolUse` hook checks a flag file and exits immediately,
adding zero latency). When on, a matched tool notifies and waits up to ~60s for your decision; if
you do not respond it defers to the normal terminal prompt. Requires the approval hook (installed
by **Install Claude Code Hooks…**).

### Forward to a webhook

Set **Webhook…** to an HTTPS URL (ntfy, Pushover, Slack, …) to also POST each notification as
JSON (`title`, `message`, `status`, `source`) so it reaches your phone when you are away.

### Banner modes (avoid double accumulation)

Because the app keeps its own persistent inbox, the native macOS banner defaults to
**Auto-dismiss**: it pops up as a fleeting arrival cue, then removes itself from Notification
Center a few seconds later, so notifications do not pile up in two places. Choose **Keep in
Notification Center** to leave the banner there as before, or **Off** to suppress the banner
(the inbox, Dock badge, menu-bar count, and sound still work).

### Menu bar item

A bell in the system menu bar shows the unread count and stays visible even when the Dock is
hidden or you are in full-screen. Click it to open the inbox or reach Settings.

### Persistence

The inbox is saved to `~/Library/Application Support/claude-notifier/inbox.json` and restored
on launch, so unread notifications and the badge survive a quit, crash, or login restart. A
corrupt file is moved aside automatically and the app starts with an empty inbox.

### Quiet (focused) tab

If a notification fires for the frontmost iTerm2 tab you are already looking at, it lands silently in the
inbox as read history (no banner, no sound, no badge bump), since you are clearly already there.

## Click-to-Focus

Clicking a notification row, or the native banner, activates the originating terminal:

| Terminal | Behavior |
|----------|----------|
| iTerm2 | Activates iTerm2 + focuses the specific tab via native API (WebSocket + protobuf) |
| iTerm2 (tmux) | Resolves tmux window to iTerm2 tab via ListSessions API, then activates |
| VS Code | Activates VS Code |
| Terminal.app | Selects the matching tab by `tty` (first focus prompts for Automation permission), then activates Terminal.app |
| Zed | Focuses the workspace window for the notification's `workdir` via the `zed` CLI (reopens it if closed), then activates the app |
| Ghostty / WezTerm / kitty / Alacritty / Warp | Activates the app (app-level focus; no tab focus) |
| Other | Activates by `bundle` id when the hook provided one; otherwise notification only |

**tmux re-attach:** when the notification carries `tmux_socket` + `tmux_session`, the click asks
the tmux server which client is attached *at that moment* (most recently active one when several
are) and focuses that terminal, so a session re-attached from a different terminal after the
notification fired is still focused correctly. With no client attached, the terminal recorded at
notification time is used.

## Architecture

- **Resident windowed app** — launches once, stays alive via `NSApplication.run()`; closing the window keeps it running in the background, and clicking the Dock icon reopens it (`applicationShouldTerminateAfterLastWindowClosed` returns false)
- **Notification inbox** — `NotificationStore` holds the list; `InboxViewController` renders rows in an `NSScrollView`, hosted as the window's `contentViewController`
- **Persistent inbox** — the store is `Codable` and saved (debounced, atomic) to Application Support, restored on launch, and self-heals a corrupt file
- **Menu-bar status item** — `NSStatusItem` bell with the unread count; visible even when the Dock is hidden or in full-screen
- **Custom URL scheme** (`claude-notifier://`) — IPC from hooks to app
- **iTerm2 native API** — WebSocket + Protocol Buffers over Unix domain socket, no external dependencies
- **Dock icon + menu bar** — `.regular` activation policy; settings live in the menu bar and the in-window gear button
- **One notification per tab** — same-tab notifications (keyed by tmux window id, else iTerm2 session) replace each other (sound always replays)
- **Ad-hoc codesigned** — no Xcode project, builds with `swiftc` only
