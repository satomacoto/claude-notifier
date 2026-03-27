# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A lightweight macOS native notification app for Claude Code hooks. Single Swift file compiled into a `.app` bundle without Xcode. Tapping a notification focuses the originating terminal (iTerm2 tab-level, VS Code, Terminal.app).

## Build & Install

```bash
./build.sh                                          # compiles → build/claude-notifier.app
cp -r build/claude-notifier.app ~/Applications/     # install
```

Build uses `swiftc` directly (no Xcode project, no Swift Package Manager). Ad-hoc codesigned.

## Architecture

- **Sources/main.swift** — entire app: CLI arg parsing, `NSUserNotification` delivery, tap-to-focus delegate, 30s auto-exit. Uses `NSUserNotificationCenter` (not `UNUserNotificationCenter`).
- **Resources/focus_iterm.py** — Python script using `iterm2` package to focus a specific iTerm2 session. Currently unused at runtime (the app calls `it2` CLI instead), but bundled in the app.
- **build.sh** — compiles Swift, assembles `.app` bundle (Contents/MacOS + Info.plist + Resources), ad-hoc codesigns.
- **Info.plist** — `LSUIElement=true` (no Dock icon), `NSUserNotificationAlertStyle=alert`.

## Key Design Decisions

- Terminal type is detected from env vars (`ITERM_SESSION_ID`, `TERM_PROGRAM`) at notification-send time and stored in `notification.userInfo` so the tap handler has context even if relaunched.
- iTerm2 session focus uses the `it2` CLI tool (hardcoded path `/Users/sato/.local/bin/it2`), not the bundled Python script.
- The app runs as an accessory app (`.accessory` activation policy) — no Dock icon, no menu bar.
- Each invocation sends one notification and exits (after tap or 30s timeout).

## Integration

Used as a Claude Code hook via `open ~/Applications/claude-notifier.app --args ...`. The hook captures iTerm2 session ID at `SessionStart` and pipes notification JSON through `jq` at `Notification` time. See README.md for the full hooks config.
