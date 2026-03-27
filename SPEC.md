# claude-notifier

macOS native notification sender for Claude Code, with terminal-aware tap-to-focus.

## Goal

A lightweight macOS app that sends notifications from Claude Code hooks.
Tapping the notification brings the user back to the terminal where Claude Code is running.
Notification title includes the project name so users can identify which session needs attention.

## Requirements

- Send macOS native notifications with title, message, and optional sound
- Include project name in notification title (from `$PWD` basename)
- Tap-to-focus: activate the originating terminal app on notification tap
  - iTerm2: activate + focus specific tab/session via Python API
  - VS Code: activate VS Code window
  - Other terminals: activate the terminal app
- Usable from Claude Code hooks
- No Xcode required — builds with `swift` CLI only
- Minimal dependencies (Apple frameworks only + iTerm2 Python API for tab focus)

## Usage

```bash
# Basic (project name auto-detected from $PWD)
claude-notifier --message "Ready"

# With explicit title and sound
claude-notifier --title "Claude Code" --message "Ready" --sound "Ping"

# Message from stdin
echo "Ready" | claude-notifier --sound Ping

# Specify iTerm2 session (auto-detected from $ITERM_SESSION_ID if omitted)
claude-notifier --message "Ready" --iterm-session "w0t2p0:UUID"
```

## CLI Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `--title` | No | `"Claude Code — {project}"` | Notification title. `{project}` is replaced with `$PWD` basename |
| `--message` | No | Read from stdin | Notification body |
| `--sound` | No | None | Sound name (e.g. `Ping`, `Glass`) |
| `--iterm-session` | No | `$ITERM_SESSION_ID` env var | iTerm2 session ID to focus on tap |

## Architecture

- Single Swift file compiled into a `.app` bundle
- Uses `UserNotifications` framework (UNUserNotificationCenter)
- `.app` bundle structure created via build script (no Xcode project)
- LSUIElement=true in Info.plist (no Dock icon, no menu bar)
- UNUserNotificationCenterDelegate handles notification tap events

## Tap-to-focus behavior

The app detects the terminal environment from environment variables and activates the appropriate app on tap:

| Environment | Detection | Tap action |
|-------------|-----------|------------|
| iTerm2 | `$ITERM_SESSION_ID` is set | Activate iTerm2 + focus specific tab via Python API |
| VS Code | `$TERM_PROGRAM == "vscode"` | Activate VS Code (`com.microsoft.VSCode`) |
| Terminal.app | `$TERM_PROGRAM == "Apple_Terminal"` | Activate Terminal.app |
| Other | fallback | No app activation (notification only) |

The terminal type and session info are stored in the notification's `userInfo` dict at send time, so they are available when the tap handler runs (even if the app was relaunched).

### iTerm2 Python API integration

When iTerm2 is detected, the tap handler invokes a bundled Python script to focus the specific tab:

```python
#!/usr/bin/env python3
import iterm2
import sys

async def main(connection):
    app = await iterm2.async_get_app(connection)
    session = app.get_session_by_id(sys.argv[1])
    if session:
        await session.async_activate(select_tab=True, order_window_front=True)

iterm2.run_until_complete(main)
```

Requires: `iterm2` Python package (`pip install iterm2` or `uv pip install iterm2`)
Requires: iTerm2 > Settings > General > Magic > "Enable Python API" checked

## Build

```bash
./build.sh
# Outputs: build/claude-notifier.app
```

build.sh:
1. Compile Swift source with `swiftc`
2. Create .app bundle structure (Contents/MacOS, Contents/Info.plist, Contents/Resources)
3. Copy Python focus script to Resources

## Install

```bash
cp -r build/claude-notifier.app ~/Applications/
# Or symlink the binary:
ln -s /path/to/claude-notifier.app/Contents/MacOS/claude-notifier /usr/local/bin/claude-notifier
```

## Integration with Claude Code hooks

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "MSG=$(cat | jq -r '.message // \"Claude Code is ready\"') && /path/to/claude-notifier.app/Contents/MacOS/claude-notifier --message \"$MSG\" --sound Ping"
          }
        ]
      }
    ]
  }
}
```

Environment variables (`$ITERM_SESSION_ID`, `$TERM_PROGRAM`, `$PWD`) are automatically
inherited from the hook execution context. No additional arguments needed.

## File structure

```
claude-notifier/
├── SPEC.md
├── build.sh
├── Sources/
│   └── main.swift
├── Resources/
│   └── focus_iterm.py
└── build/           (generated)
    └── claude-notifier.app/
        └── Contents/
            ├── Info.plist
            ├── MacOS/
            │   └── claude-notifier
            └── Resources/
                └── focus_iterm.py
```
