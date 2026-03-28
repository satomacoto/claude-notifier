# claude-notifier

macOS native notification daemon for Claude Code, with terminal-aware tap-to-focus.

Runs as a resident background app. Claude Code hooks send notifications via custom URL scheme — no process spawning per notification.

## Prerequisites

- **macOS** (uses NSUserNotificationCenter)
- **Swift** compiler (`swiftc`) — included with Xcode Command Line Tools
- **jq** — for parsing hook input (`brew install jq`)
- **python3** — for URL encoding in hook command
- **it2** — for iTerm2 tab focus (`uv tool install it2`)

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
open --background "claude-notifier://notify?message=Hello"

# With title and sound
open --background "claude-notifier://notify?title=MyProject&message=Ready&sound=Ping"

# With iTerm2 tab focus
open --background "claude-notifier://notify?title=MyProject&message=Ready&sound=Ping&terminal=iterm2&session=SESSION_ID"

# Quit the app
open "claude-notifier://quit"
```

### URL Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `title` | No | `Claude Code` | Notification title |
| `message` | No | (empty) | Notification body |
| `sound` | No | None | Sound name (e.g. `Ping`, `Glass`, `Submarine`) |
| `terminal` | No | `unknown` | Terminal type: `iterm2`, `vscode`, `terminal` |
| `session` | No | None | iTerm2 session ID for tab-level focus |

All values must be URL-encoded.

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
            "command": "it2 session get-var id > /tmp/claude-session-id-$PPID 2>/dev/null || true"
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
            "command": "MSG=$(cat | jq -r '.message // \"Claude Code is ready\"') && SID=$(cat /tmp/claude-session-id-$PPID 2>/dev/null || echo '') && PROJECT=$(basename \"$PWD\") && MSG_ENC=$(python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$MSG\") && TITLE_ENC=$(python3 -c \"import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))\" \"$PROJECT\") && open \"claude-notifier://notify?title=$TITLE_ENC&message=$MSG_ENC&sound=Ping&terminal=iterm2&session=$SID\""
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
| iTerm2 | Activates iTerm2 + focuses the specific tab/session via `it2` |
| VS Code | Activates VS Code |
| Terminal.app | Activates Terminal.app |
| Other | Notification only |

## Architecture

- **Resident background app** — launches once, stays alive via `NSApplication.run()`
- **Custom URL scheme** (`claude-notifier://`) — IPC from hooks to app
- **LSUIElement=true** — no Dock icon, no menu bar
- **One notification per session** — same-tab notifications replace each other (sound always replays)
- **Ad-hoc codesigned** — no Xcode project, builds with `swiftc` only
