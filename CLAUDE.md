# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A lightweight macOS native notification manager for Claude Code hooks. Single Swift file compiled into a `.app` bundle without Xcode. It is a regular windowed app (Dock icon) whose main window is a scrollable inbox of recent notifications; clicking a row focuses the originating terminal (iTerm2 tab-level, VS Code, Terminal.app). Closing the window keeps the app running in the background; the Dock icon reopens it.

## Build & Install

```bash
./build.sh                                          # compiles → build/claude-notifier.app
cp -r build/claude-notifier.app ~/Applications/     # install
```

Build uses `swiftc` directly (no Xcode project, no Swift Package Manager). Ad-hoc codesigned.

## Architecture

- **Sources/main.swift** — entire app. Notification model + store (`NotifStatus`, `NotificationItem`, `NotificationStore`), inbox UI (`NotificationRowView`, `InboxViewController` hosted as the window's `contentViewController`), URL scheme handler, native-banner delivery + click-to-focus delegate, menu-bar menus (App/Notifications/Settings/Window). Still uses `NSUserNotificationCenter` (not `UNUserNotificationCenter`) for the optional native banner.
- **build.sh** — compiles Swift, assembles `.app` bundle (Contents/MacOS + Info.plist + Resources), ad-hoc codesigns.
- **Info.plist** — `LSUIElement=false` (regular app, Dock icon), `NSUserNotificationAlertStyle=alert`.

## Key Design Decisions

- Terminal type is detected from env vars (`ITERM_SESSION_ID`, `TERM_PROGRAM`) at notification-send time and stored in `notification.userInfo` so the tap handler has context even if relaunched.
- **iTerm2 session focus uses iTerm2's native API directly** — WebSocket + Protocol Buffers over Unix domain socket (`~/Library/Application Support/iTerm2/private/socket`). No external dependencies (no `it2` CLI, no Python, no iterm2 package).
  - **Non-tmux**: sends `ActivateRequest` with `session_id` (UUID extracted from `ITERM_SESSION_ID`).
  - **tmux integration**: sends `ListSessionsRequest` to find the tab matching `tmux_window_id`, then sends `ActivateRequest` with `tab_id`.
- Protobuf encoding/decoding is hand-rolled (minimal subset) to avoid SwiftProtobuf dependency.
- The app runs as a resident regular app (`.regular` activation policy, Dock icon). `applicationShouldTerminateAfterLastWindowClosed` returns false and `applicationShouldHandleReopen` reopens the window, so closing the window keeps the notifier alive in the background.
- Notifications are kept until acted on or dismissed (acted-on ones stay as dimmed read history); a `FocusMonitor` watches the active iTerm2 session/tab and auto-marks the matching pending notification read. The Dock badge shows the unread count.
- tmux notifications intentionally store `sessionUUID = nil` (matched by resolved `tabId` only), because a tmux session id is shared across windows and matching by session would wrongly clear other windows' notifications.

## URL Scheme

`claude-notifier://notify?title=...&message=...&terminal=iterm2&session=<ITERM_SESSION_ID>&tmux_window_id=<@N>&status=<state>`

- `session` — iTerm2 session ID (for non-tmux)
- `tmux_window_id` — tmux window ID like `@4` (for tmux integration; `@` prefix is stripped automatically)
- `status` — status dot color: `running`, `waiting`, `review` (default), `done`, `failed`, `message`
- `sound` — optional sound name overriding the user/per-project default

## Integration

Used as a Claude Code hook via URL scheme. The hook captures iTerm2 session ID and tmux window ID at `SessionStart` and opens the URL scheme at `Notification` time. See README.md for the full hooks config.
