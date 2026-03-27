# claude-notifier

macOS native notification sender for Claude Code, with terminal-aware tap-to-focus.

## Prerequisites

- **macOS** (uses NSUserNotificationCenter)
- **Swift** compiler (`swiftc`) - included with Xcode Command Line Tools
- **jq** - for parsing hook input (`brew install jq`)
- **it2** - for iTerm2 tab focus (`uv tool install it2`)
- **iTerm2 Python API** - Enable in iTerm2 > Settings > General > Magic > "Enable Python API"

## macOS permissions

The following permissions must be enabled in **System Settings**:

1. **Privacy & Security > App Management** - Allow `claude-notifier.app` (required for tap-to-focus)
2. **Notifications** - Allow notifications from `claude-notifier` (System Settings > Notifications)

## Build

```bash
./build.sh
```

## Install

```bash
cp -r build/claude-notifier.app ~/Applications/
```

## Usage

```bash
# Basic
claude-notifier --message "Ready"

# With sound
claude-notifier --title "Claude Code" --message "Ready" --sound Ping

# With iTerm2 session (for tap-to-focus)
claude-notifier --message "Ready" --sound Ping --iterm-session "$(it2 session get-var id)"
```

### CLI Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `--title` | No | `Claude Code — {project}` | Notification title (`{project}` = basename of `$PWD`) |
| `--message` | No | Read from stdin | Notification body |
| `--sound` | No | None | Sound name (e.g. `Ping`, `Glass`, `Submarine`) |
| `--iterm-session` | No | None | iTerm2 session ID from `it2 session get-var id` |

## Claude Code hooks integration

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
            "command": "MSG=$(cat | jq -r '.message // \"Claude Code is ready\"') && SID=$(cat /tmp/claude-session-id-$PPID 2>/dev/null) && PROJECT=$(basename \"$PWD\") && ~/Applications/claude-notifier.app/Contents/MacOS/claude-notifier --title \"Claude Code — $PROJECT\" --message \"$MSG\" --sound Ping --iterm-session \"$SID\" &"
          }
        ]
      }
    ]
  }
}
```

## Tap-to-focus

Tapping the notification activates the terminal where Claude Code is running:

| Terminal | Behavior |
|----------|----------|
| iTerm2 | Activates iTerm2 + focuses the specific tab/session via `it2` |
| VS Code | Activates VS Code |
| Terminal.app | Activates Terminal.app |
| Other | Notification only |
