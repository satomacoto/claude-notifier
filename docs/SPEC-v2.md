# claude-notifier v2 — Resident Notification App

macOS native notification daemon for Claude Code hooks, with terminal-aware tap-to-focus.

## Goals

- **Resident app**: Single long-running process handles all notifications (no more one-shot spawning)
- **Reliable tap-to-focus**: Since the app is always alive, notification tap delegates always fire
- **Multiple notification tracking**: Each notification carries its own terminal context in `userInfo`
- **Simple IPC**: Claude Code hooks send requests via custom URL scheme (`open` command)
- **No Xcode required**: Builds with `swiftc` only, ad-hoc codesigned

## Architecture

```
[Claude Code Hook]
  │
  │  open "claude-notifier://notify?title=...&message=...&session=..."
  ▼
[Resident App]  (LSUIElement=true, no Dock icon)
  │
  ├─ AppDelegate.application(_:open:)  ← receives URL
  │    └─ Parse query params → create NSUserNotification → deliver
  │
  ├─ NotificationDelegate.didActivate()  ← user taps notification
  │    └─ Read userInfo → focus terminal (iTerm2/VSCode/Terminal.app)
  │
  └─ RunLoop keeps app alive indefinitely
```

## IPC: Custom URL Scheme

### Why URL Scheme

- CLI call is one line: `open "claude-notifier://notify?..."`
- No extra CLI tools needed
- macOS handles app launch & message routing
- If app isn't running, macOS launches it automatically
- Minimal implementation (~50-100 lines)
- No special permissions or entitlements

### URL Format

```
claude-notifier://notify?title=TITLE&message=MESSAGE&sound=SOUND&terminal=TYPE&session=SESSION_ID
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `title` | No | Notification title. Default: `Claude Code` |
| `message` | No | Notification body. Default: empty |
| `sound` | No | Sound name (e.g. `Ping`, `Glass`) |
| `terminal` | No | Terminal type: `iterm2`, `vscode`, `terminal`, `unknown` |
| `session` | No | iTerm2 session ID for tab-level focus |

All values must be URL-encoded.

### Limitation

URL length ~2KB. Sufficient for notification title + message + metadata.
If message is too long, truncate to a reasonable length.

## Lifecycle

### Startup

1. First `open "claude-notifier://..."` call launches the app (if not already running)
2. App registers as `.accessory` (no Dock icon, no menu bar)
3. App registers URL scheme handler and notification delegate
4. Subsequent `open` calls are routed to the running instance

### Steady State

- App stays alive via `NSApplication.run()` (RunLoop)
- Each incoming URL → parse → deliver notification
- Each notification tap → read `userInfo` → focus terminal → remove notification
- Multiple notifications can coexist, each with independent `userInfo`

### Shutdown

- No automatic shutdown (resident app)
- Can be quit manually via Activity Monitor or `killall claude-notifier`
- Optionally: `claude-notifier://quit` URL to gracefully terminate

## Notification Delivery

- Uses `NSUserNotification` + `NSUserNotificationCenter` (same as v1)
- Each notification gets a unique identifier (UUID)
- `userInfo` stores: `terminalType`, `itermSession`, `notificationId`
- `shouldPresent` delegate always returns `true` to show even when app is "frontmost"

### Future: UNUserNotificationCenter Migration

NSUserNotification is deprecated since macOS 11. Current plan:
- **Short term (1-2 years)**: Keep NSUserNotification — it still works on macOS 15
- **Long term**: Migrate to UNUserNotificationCenter when needed
  - Requires `requestAuthorization()` for permission
  - `userInfo` persists across app restarts (bonus: tap works even if app crashes)

## Tap-to-Focus

Same behavior as v1, read from notification's `userInfo`:

| Terminal | Detection | Tap Action |
|----------|-----------|------------|
| iTerm2 | `terminal=iterm2` | Activate iTerm2 + `it2 session focus <session>` |
| VS Code | `terminal=vscode` | Activate VS Code |
| Terminal.app | `terminal=terminal` | Activate Terminal.app |
| Other | `terminal=unknown` | No action |

Note: `it2` path should be resolved via `$PATH` (not hardcoded).

## Graceful Shutdown

- `claude-notifier://quit` URL triggers `NSApp.terminate(nil)`
- SIGTERM signal handler for graceful shutdown (cleanup delivered notifications)
- `killall claude-notifier` also works

## Info.plist Changes

Add URL scheme registration:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.satomacoto.claude-notifier</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>claude-notifier</string>
    </array>
  </dict>
</array>
```

## App Structure

```swift
// main.swift — resident notification daemon

// 1. AppDelegate: handles URL scheme events + app lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Parse URL query → deliver notification
    }
}

// 2. NotificationDelegate: handles notification tap
class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    func userNotificationCenter(_:didActivate:) {
        // Read userInfo → focus terminal
    }
    func userNotificationCenter(_:shouldPresent:) -> Bool {
        return true  // Always show
    }
}

// 3. Main: setup and run
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
// ... setup notification center delegate
app.run()  // Runs forever
```

## Claude Code Hooks Integration

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
            "command": "MSG=$(cat | jq -r '.message // \"Claude Code is ready\"') && SID=$(cat /tmp/claude-session-id-$PPID 2>/dev/null || echo '') && PROJECT=$(basename \"$PWD\") && TITLE=$(python3 -c \"import urllib.parse; print(urllib.parse.quote('Claude Code — '$PROJECT''))\") && MSG_ENC=$(python3 -c \"import urllib.parse; print(urllib.parse.quote('$MSG'))\") && open \"claude-notifier://notify?title=$TITLE&message=$MSG_ENC&sound=Ping&terminal=iterm2&session=$SID\""
          }
        ]
      }
    ]
  }
}
```

## Build

```bash
./build.sh  # compiles → build/claude-notifier.app
```

Same build process as v1:
1. `swiftc -framework AppKit` → compile
2. Assemble `.app` bundle (Contents/MacOS + Info.plist + Resources)
3. Ad-hoc codesign

## Install

```bash
cp -r build/claude-notifier.app ~/Applications/
```

## macOS Permissions

1. **Privacy & Security > App Management** — Allow `claude-notifier.app`
2. **Notifications** — Allow notifications from `claude-notifier`

## Migration from v1

| Aspect | v1 (current) | v2 (resident) |
|--------|-------------|---------------|
| Lifecycle | One-shot: spawn → notify → exit 30s | Resident: launch once, stays alive |
| IPC | CLI args + stdin | Custom URL scheme |
| Multiple notifications | One per process | Multiple, each tracked by UUID |
| Tap after timeout | Broken (app dead) | Always works (app alive) |
| Process count | One per notification | One total |
| Hook command | Direct binary execution | `open "claude-notifier://..."` |

## File Structure

```
claude-notifier/
├── SPEC-v2.md          ← this file
├── Sources/
│   └── main.swift      ← rewrite: resident app with URL scheme handler
├── Info.plist          ← add CFBundleURLTypes
├── build.sh            ← unchanged
├── Resources/          ← focus_iterm.py removed (dead code in v1)
└── build/
    └── claude-notifier.app/
```
