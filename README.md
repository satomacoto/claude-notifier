# claude-notifier

macOS native notification daemon for Claude Code, with terminal-aware tap-to-focus.

Runs as a resident menu bar app. Claude Code hooks send notifications via custom URL scheme — no process spawning per notification.

## Prerequisites

- **macOS** (uses NSUserNotificationCenter)
- **Swift** compiler (`swiftc`) — included with Xcode Command Line Tools
- **jq** — for parsing hook input (`brew install jq`)
- **python3** — for URL encoding in hook command
- **iTerm2** with Python API enabled (Preferences > General > Magic > Enable Python API) — for tab focus

## macOS Permissions

1. **Privacy & Security > App Management** — Allow `claude-notifier.app`
2. **Notifications** — Allow notifications from `claude-notifier` (System Settings > Notifications)

## Build & Install

```bash
./build.sh
cp -r build/claude-notifier.app ~/Applications/
```

First launch to register the URL scheme:

```bash
open ~/Applications/claude-notifier.app
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
| `terminal` | No | `unknown` | Terminal type: `iterm2`, `vscode`, `terminal` |
| `session` | No | None | iTerm2 session ID (`ITERM_SESSION_ID`) for non-tmux tab focus |
| `tmux_window_id` | No | None | tmux window ID (e.g. `@4`) for tmux integration tab focus |

All values must be URL-encoded. Use `open -g` to avoid stealing focus from the current app.

## Claude Code Hooks Integration

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo \"$ITERM_SESSION_ID\" > /tmp/claude-session-id-$PPID; if [ -n \"$TMUX\" ]; then tmux display-message -p '#{window_id}' > /tmp/claude-tmux-winid-$PPID; fi"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "MSG=$(cat | jq -r '.message // \"Claude Code is ready\"') && SID=$(cat /tmp/claude-session-id-$PPID 2>/dev/null || echo '') && TWID=$(cat /tmp/claude-tmux-winid-$PPID 2>/dev/null || echo '') && PROJECT=$(basename \"$PWD\") && MSG_ENC=$(python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$MSG\") && TITLE_ENC=$(python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$PROJECT\") && TWID_ENC=$(python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$TWID\") && open -g \"claude-notifier://notify?title=$TITLE_ENC&message=$MSG_ENC&terminal=iterm2&session=$SID&tmux_window_id=$TWID_ENC\""
          }
        ]
      }
    ]
  }
}
```

## Tap-to-Focus

Tapping a notification activates the originating terminal:

| Terminal | Behavior |
|----------|----------|
| iTerm2 | Activates iTerm2 + focuses the specific tab via native API (WebSocket + protobuf) |
| iTerm2 (tmux) | Resolves tmux window to iTerm2 tab via ListSessions API, then activates |
| VS Code | Activates VS Code |
| Terminal.app | Activates Terminal.app |
| Other | Notification only |

## Architecture

- **Resident menu bar app** — launches once, stays alive via `NSApplication.run()`
- **Custom URL scheme** (`claude-notifier://`) — IPC from hooks to app
- **iTerm2 native API** — WebSocket + Protocol Buffers over Unix domain socket, no external dependencies
- **LSUIElement=true** — no Dock icon
- **One notification per session** — same-tab notifications replace each other (sound always replays)
- **Ad-hoc codesigned** — no Xcode project, builds with `swiftc` only
