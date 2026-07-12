# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A lightweight macOS native notification manager for Claude Code hooks. Single Swift file compiled into a `.app` bundle without Xcode. It is a regular windowed app (Dock icon) whose main window is a scrollable inbox of recent notifications; clicking a row focuses the originating terminal (iTerm2 tab-level, VS Code, Terminal.app). Closing the window keeps the app running in the background; the Dock icon reopens it.

## Build & Run

```bash
./build.sh                          # compiles → build/claude-notifier.app
open build/claude-notifier.app      # launch (also registers the URL scheme)
```

Run the app from `build/claude-notifier.app` directly. Do **not** also copy it to
`~/Applications/`: the same bundle id (`com.satomacoto.claude-notifier`) registered at two paths
makes macOS treat them as separate apps, so a notification (`open claude-notifier://…`) can launch
a second instance while one is already running. If a stale `~/Applications/` copy exists, remove
and unregister it (`lsregister -u ~/Applications/claude-notifier.app; rm -rf …; lsregister -f build/claude-notifier.app`).

Build uses `swiftc` directly (no Xcode project, no Swift Package Manager). Ad-hoc codesigned.

## Architecture

- **Sources/main.swift** — entire app. Notification model + store (`NotifStatus`, `NotificationItem`, `NotificationStore`), inbox UI (`NotificationRowView`, `InboxViewController` hosted as the window's `contentViewController`), URL scheme handler, native-banner delivery + click-to-focus delegate, menu-bar menus (App/Notifications/Settings/Window). Still uses `NSUserNotificationCenter` (not `UNUserNotificationCenter`) for the optional native banner.
- **build.sh** — compiles Swift, assembles `.app` bundle (Contents/MacOS + Info.plist + Resources), ad-hoc codesigns.
- **Info.plist** — `LSUIElement=false` (regular app, Dock icon), `NSUserNotificationAlertStyle=alert`.

## Key Design Decisions

- **Terminal type is resolved at event time from the process tree and live tmux state**, not env vars (`TERM_PROGRAM` / `ITERM_SESSION_ID` / `TMUX` go stale: an editor launched from a tmux shell hands stale copies to every terminal it spawns — e.g. Zed sessions used to masquerade as iTerm). `hooks/claude-notifier-ctx.sh` (installed to `~/.claude/hooks/`, bundled into Resources by build.sh) validates tmux membership by matching claude's tty against live pane ttys, resolves the attached tmux client via `list-clients` + a process-ancestry walk to the owning `.app`, and falls back to claude's own ancestry outside tmux. It emits eval-able `CN_*` vars the hooks put into the URL (`terminal`, `terminal_name`, `bundle`, `session`, `tmux_window_id`, `tmux_socket`, `tmux_session`, `tty`); the last successful resolution is cached per pid (`/tmp/claude-notifier-ctx-cache-<pid>`) for detached-tmux fallback. Results land in `notification.userInfo` so the tap handler has context even if relaunched.
- **Click-time tmux re-resolution**: when an item carries `tmuxSocket` + `tmuxSession`, `focusTerminal` re-asks the tmux server which client is attached at click time (`resolveTmuxAttachment`: `list-clients`, most recent `client_activity`, ancestry walk, `Bundle(path:).bundleIdentifier`) and focuses that terminal, so re-attaching a session from a different terminal after the notification fired still focuses correctly. No attached client → fall back to the stored terminal.
- **iTerm2 session focus uses iTerm2's native API directly** — WebSocket + Protocol Buffers over Unix domain socket (`~/Library/Application Support/iTerm2/private/socket`). No external dependencies (no `it2` CLI, no Python, no iterm2 package).
  - **Non-tmux**: sends `ActivateRequest` with `session_id` (UUID extracted from `ITERM_SESSION_ID`).
  - **tmux integration**: sends `ListSessionsRequest` to find the tab matching `tmux_window_id`, then sends `ActivateRequest` with `tab_id`.
- Protobuf encoding/decoding is hand-rolled (minimal subset) to avoid SwiftProtobuf dependency.
- The app runs as a resident regular app (`.regular` activation policy, Dock icon). `applicationShouldTerminateAfterLastWindowClosed` returns false and `applicationShouldHandleReopen` reopens the window, so closing the window keeps the notifier alive in the background.
- Notifications are kept until acted on or dismissed (acted-on ones stay as dimmed read history); a `FocusMonitor` watches the active iTerm2 session/tab and auto-marks the matching pending notification read only while iTerm2 is frontmost. The Dock badge shows the unread count.
- tmux notifications intentionally store `sessionUUID = nil` (matched by resolved `tabId` only), because a tmux session id is shared across windows and matching by session would wrongly clear other windows' notifications.
- **Persistence**: `NotificationStore` is `Codable` and saved (debounced + atomic, plus a synchronous flush in `applicationWillTerminate`) to `~/Library/Application Support/claude-notifier/inbox.json`, restored via `load()` on launch. A corrupt file is moved aside (`.corrupt-<ts>`). `NotificationItem`'s decoder is tolerant of missing keys so adding fields never invalidates an existing inbox.
- **Banner modes** (`bannerMode`, default `transient`): `off` / `transient` (deliver then auto-remove from Notification Center after 5s, so the inbox is the only place notifications accumulate) / `persist` (legacy behavior). Migrates the old `bannerEnabled` bool. `presentBanner()` is the single delivery path (used by both `deliverNotification` and escalation).
- **Menu-bar status item** (`NSStatusItem`) shows the unread count using the bundled `menubar_icon` (template); `updateBadge()` updates both Dock and menu bar.
- **Focus-silence**: a notification for the frontmost iTerm2 tab/session you're already looking at lands silently as read (`store.add(forceRead:)`), using `activeSessionUUID`/`activeTabId` tracked from `FocusMonitor` plus the frontmost app.
- **Quiet hours / DND** (`isQuietNow()`): manual pause (`pauseUntil`) or a nightly window (`quietHoursEnabled`) suppresses banner+sound (inbox still collects).
- **One-time escalation** (`escalateMinutes`, default off): a 30s timer re-alerts once for an unread review/failed/waiting item past the threshold (`escalated` flag).
- **Sound**: priority is URL `sound` > per-status (`perStatusSound`, `NotifStatus.defaultSound`) > per-project (`perProjectSound`) > user default.
- **Webhook** (`webhookURL`): `forwardToWebhook()` POSTs each non-focused, non-muted notification as JSON (fire-and-forget `URLSession`).
- **One-command setup**: "Install Claude Code Hooks…" merges `sessionStartHookCommand` + `notificationHookCommand` + `approvalHookCommand` + `thinkingStartHookCommand` (UserPromptSubmit) + `thinkingStopHookCommand` (Stop/StopFailure) into `~/.claude/settings.json` (idempotent, timestamped backup, confirm-with-preview, refuses non-object files).
- **Left row indicator**: per-sound SF Symbol (`soundSymbols` keyed by the item's resolved `sound`, tinted by `status.color`), or an `NSProgressIndicator` spinner while `thinking`. Falls back to a colored dot on macOS < 11.
- **Inbox UI extras**: live search + status filter + **sort selector** (`sortMode`: `recent` default / `project` / `tab`, in the header filter bar). `project` groups by title then orders by tab (⌘N) then recency; `tab` orders by the iTerm shortcut `(window, tab)` with shortcut-less rows last (`tabOrderKey`); `recent` keeps store order. Plus keyboard nav (↑/↓ select, ⏎ open, ⌫ dismiss; id-based selection), compact-row toggle (`compactRows`), and an iTerm2 connection health dot in the header. The header's clear link is **Clear read** (`store.clearRead()` removes acted-on/read rows, keeping pending + thinking; shown only when `store.hasRead`); the full **Clear All** (`store.clearAll()`) lives in the Notifications menu.

## URL Scheme

`claude-notifier://notify?title=...&message=...&terminal=<type>&session=<ITERM_SESSION_ID>&tmux_window_id=<@N>&tty=<dev>&status=<state>`

- `terminal` — `iterm2`, `vscode`, `terminal`, `ghostty`, `wezterm`, `kitty`, `alacritty`, `warp`, `zed` (resolved by the ctx script from the process tree / attached tmux client). iTerm2 gets tab-level focus; Terminal.app gets tab focus via `tty`; the rest get app-level focus (`terminalBundleIDs`, overridable per notification via the `bundle` param; `terminal_name` likewise overrides the display name). **Legacy tmux note:** old env-var hooks sent `terminal=unknown` inside tmux; both `deliverNotification` and `focusTerminal` still normalize `unknown` → `iterm2` when the `session` carries an iTerm session UUID (`extractSessionUUID(s) != s`). The ctx-script hooks instead send the real terminal plus `tmux_socket`/`tmux_session` for click-time re-resolution, and a stable `session=pid-<pid>` key for non-iTerm non-tmux sessions.
- App-level focus uses `NSWorkspace.openApplication` (LaunchServices), **not** AppleScript — so it needs no Automation (Apple Events / TCC) permission and keeps working across ad-hoc re-signs. Terminal.app per-tab focus still uses AppleScript (needs Automation).
- **Live ⌘N refresh:** a tab's stored shortcut/`tabId` goes stale when iTerm tabs are reordered/closed (the tmux window id is stable, the position isn't). `refreshTabShortcuts()` (called from `showWindow()` and a 4s timer while the window is visible) does one `iterm2ResolveAllTmuxShortcuts()` ListSessions off the main thread and `store.updateRouting(map)` updates each tmux row's current shortcut/tabId. **Gotcha:** iTerm2's ListSessions returns tmux window ids without the `@` prefix, so `updateRouting` strips `@` before matching the stored `tmux` (e.g. `@50`).
- `session` — iTerm2 session ID (for non-tmux)
- `tmux_window_id` — tmux window ID like `@4` (for tmux integration; `@` prefix is stripped automatically)
- `workdir` — project root path (git toplevel or `$PWD` at hook time). For `terminal=zed`, a click runs the `zed` CLI (`/opt/homebrew/bin/zed`, `/usr/local/bin/zed`, or `<Zed.app>/Contents/MacOS/cli`) with this path, which raises the existing workspace window (or reopens it), before the app-level activation (`zedOpenWorkspace`).
- `tty` — controlling tty like `/dev/ttys004` (Terminal.app tab focus via AppleScript)
- `status` — status dot color: `running`, `waiting`, `review` (default), `done`, `failed`, `message`
- `sound` — optional sound name overriding the user/per-project default
- `source` — optional meta tag (`recap`/`title`/`alert`)
- `tool` — optional tool name (e.g. `Bash`) shown in the row meta
- `thinking` — live "Claude is working" state. `start` (with `status=running`) adds a **silent** spinner row for the tab (no banner/sound, excluded from `unreadCount`); `stop` ends it via `store.finishThinking` — the spinner stops and the row stays as quiet, clickable history (`thinking=false`, `read=true`), so you can still jump to the tab; a real notification that arrived mid-turn (no longer thinking) is left as-is. Backed by the `thinking: Bool` field on `NotificationItem` and rendered as an `NSProgressIndicator` spinner in `NotificationRowView`.

## Integration

Used as a Claude Code hook via URL scheme. Every hook resolves the terminal context live by eval-ing `~/.claude/hooks/claude-notifier-ctx.sh $PPID` (SessionStart just warms its cache), opens the URL scheme at `Notification` time, and drives the live thinking indicator via `UserPromptSubmit` (start) + `Stop`/`StopFailure` (stop). `Stop` does not fire on Esc, so `StopFailure` and the `idle_prompt` Notification act as recovery. See README.md for the full hooks config, or use the in-app "Install Claude Code Hooks…" menu item (`installClaudeHooks` upserts all of SessionStart / Notification / PreToolUse / UserPromptSubmit / Stop / StopFailure).
