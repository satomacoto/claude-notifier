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
- **Persistence**: `NotificationStore` is `Codable` and saved (debounced + atomic, plus a synchronous flush in `applicationWillTerminate`) to `~/Library/Application Support/claude-notifier/inbox.json`, restored via `load()` on launch. A corrupt file is moved aside (`.corrupt-<ts>`). `NotificationItem`'s decoder is tolerant of missing keys so adding fields never invalidates an existing inbox.
- **Banner modes** (`bannerMode`, default `transient`): `off` / `transient` (deliver then auto-remove from Notification Center after 5s, so the inbox is the only place notifications accumulate) / `persist` (legacy behavior). Migrates the old `bannerEnabled` bool. `presentBanner()` is the single delivery path (used by both `deliverNotification` and escalation).
- **Menu-bar status item** (`NSStatusItem`) shows the unread count using the bundled `menubar_icon` (template); `updateBadge()` updates both Dock and menu bar.
- **Focus-silence**: a notification for the iTerm2 tab/session you're already looking at lands silently as read (`store.add(forceRead:)`), using `activeSessionUUID`/`activeTabId` tracked from `FocusMonitor`.
- **Quiet hours / DND** (`isQuietNow()`): manual pause (`pauseUntil`) or a nightly window (`quietHoursEnabled`) suppresses banner+sound (inbox still collects).
- **One-time escalation** (`escalateMinutes`, default off): a 30s timer re-alerts once for an unread review/failed/waiting item past the threshold (`escalated` flag).
- **Sound**: priority is URL `sound` > per-status (`perStatusSound`, `NotifStatus.defaultSound`) > per-project (`perProjectSound`) > user default.
- **Webhook** (`webhookURL`): `forwardToWebhook()` POSTs each non-focused, non-muted notification as JSON (fire-and-forget `URLSession`).
- **One-command setup**: "Install Claude Code Hooks…" merges `sessionStartHookCommand` + `notificationHookCommand` into `~/.claude/settings.json` (idempotent, timestamped backup, confirm-with-preview, refuses non-object files).
- **Inbox UI extras**: live search + status filter (`InboxRootView` forwards keys), keyboard nav (↑/↓ select, ⏎ open, ⌫ dismiss; id-based selection), compact-row toggle (`compactRows`), and an iTerm2 connection health dot in the header.

## URL Scheme

`claude-notifier://notify?title=...&message=...&terminal=<type>&session=<ITERM_SESSION_ID>&tmux_window_id=<@N>&tty=<dev>&status=<state>`

- `terminal` — `iterm2`, `vscode`, `terminal`, `ghostty`, `wezterm`, `kitty`, `alacritty`, `warp` (derived from `$TERM_PROGRAM` in the hook). iTerm2 gets tab-level focus; Terminal.app gets tab focus via `tty`; the rest get app-level focus (`terminalBundleIDs`).
- `session` — iTerm2 session ID (for non-tmux)
- `tmux_window_id` — tmux window ID like `@4` (for tmux integration; `@` prefix is stripped automatically)
- `tty` — controlling tty like `/dev/ttys004` (Terminal.app tab focus via AppleScript)
- `status` — status dot color: `running`, `waiting`, `review` (default), `done`, `failed`, `message`
- `sound` — optional sound name overriding the user/per-project default
- `source` — optional meta tag (`recap`/`title`/`alert`)
- `tool` — optional tool name (e.g. `Bash`) shown in the row meta

## Integration

Used as a Claude Code hook via URL scheme. The hook captures iTerm2 session ID, `$TERM_PROGRAM`, controlling tty, and tmux window ID at `SessionStart` and opens the URL scheme at `Notification` time. See README.md for the full hooks config, or use the in-app "Install Claude Code Hooks…" menu item.
