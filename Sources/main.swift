import AppKit
import ServiceManagement

// MARK: - Constants

let availableSounds = ["", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                       "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
// Sounds used for automatic per-project assignment (excluding "" and common defaults)
let projectSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                     "Morse", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

let defaultsKeySound = "defaultSound"
let defaultsKeyPerProjectSound = "perProjectSound"
let defaultsKeyPerStatusSound = "perStatusSound"

// Deterministic hash (FNV-1a, 64-bit) so a given project name always maps to
// the same per-project sound across app restarts. Swift's built-in
// String.hashValue is seeded randomly per process, so using it would reshuffle
// every project's sound each time the app relaunches.
func stableSoundIndex(_ s: String, _ count: Int) -> Int {
    var h: UInt64 = 14695981039346656037 // FNV offset basis
    for byte in s.utf8 {
        h = (h ^ UInt64(byte)) &* 1099511628211 // FNV prime
    }
    return Int(h % UInt64(count))
}

// MARK: - URL Query Parsing

func parseQueryParams(from url: URL) -> [String: String] {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let queryItems = components.queryItems else {
        return [:]
    }
    var params: [String: String] = [:]
    for item in queryItems {
        if let value = item.value {
            params[item.name] = value
        }
    }
    return params
}

// MARK: - iTerm2 API (WebSocket + Protobuf)

/// Extract UUID from iTerm2 session ID (e.g. "w0t0p0:UUID" -> "UUID").
func extractSessionUUID(_ sessionID: String) -> String {
    if let range = sessionID.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
                                   options: .regularExpression) {
        return String(sessionID[range])
    }
    return sessionID
}

// -- Protobuf encoding helpers --

private func protoVarint(_ value: UInt64) -> Data {
    var data = Data()
    var v = value
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v > 0 { byte |= 0x80 }
        data.append(byte)
    } while v > 0
    return data
}

private func protoField(_ fieldNumber: Int, wireType: Int, payload: Data) -> Data {
    var data = protoVarint(UInt64((fieldNumber << 3) | wireType))
    if wireType == 2 { // length-delimited
        data.append(protoVarint(UInt64(payload.count)))
    }
    data.append(payload)
    return data
}

/// ActivateRequest.App { ignoring_other_apps(2): true }
private func activateAppPayload() -> Data {
    return protoField(2, wireType: 0, payload: Data([0x01]))
}

private func buildActivateSessionMessage(sessionID: String) -> Data {
    var activateReq = Data()
    activateReq.append(protoField(3, wireType: 2, payload: Data(sessionID.utf8))) // session_id
    activateReq.append(protoField(4, wireType: 0, payload: Data([0x01])))         // order_window_front
    activateReq.append(protoField(5, wireType: 0, payload: Data([0x01])))         // select_tab
    activateReq.append(protoField(6, wireType: 0, payload: Data([0x01])))         // select_session
    activateReq.append(protoField(7, wireType: 2, payload: activateAppPayload())) // activate_app

    var msg = Data()
    msg.append(protoField(1, wireType: 0, payload: Data([0x01])))
    msg.append(protoField(114, wireType: 2, payload: activateReq))
    return msg
}

private func buildActivateTabMessage(tabID: String) -> Data {
    var activateReq = Data()
    activateReq.append(protoField(2, wireType: 2, payload: Data(tabID.utf8)))     // tab_id
    activateReq.append(protoField(4, wireType: 0, payload: Data([0x01])))         // order_window_front
    activateReq.append(protoField(5, wireType: 0, payload: Data([0x01])))         // select_tab
    activateReq.append(protoField(7, wireType: 2, payload: activateAppPayload())) // activate_app

    var msg = Data()
    msg.append(protoField(1, wireType: 0, payload: Data([0x03])))
    msg.append(protoField(114, wireType: 2, payload: activateReq))
    return msg
}

// -- WebSocket over Unix domain socket --

private func iterm2SocketPath() -> String {
    return NSHomeDirectory() + "/Library/Application Support/iTerm2/private/socket"
}

private func connectUDS(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        let cstr = path.utf8CString
        precondition(cstr.count <= buf.count)
        for (i, c) in cstr.enumerated() {
            buf[i] = UInt8(bitPattern: c)
        }
    }

    let ok = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else { Darwin.close(fd); return nil }
    return fd
}

private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    return data.withUnsafeBytes { ptr -> Bool in
        var sent = 0
        while sent < data.count {
            let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }
}

private func recvUntil(_ fd: Int32, _ terminator: Data, maxBytes: Int = 8192) -> Data? {
    var buf = Data()
    var byte: UInt8 = 0
    while buf.count < maxBytes {
        let n = Darwin.read(fd, &byte, 1)
        guard n == 1 else { return nil }
        buf.append(byte)
        if buf.count >= terminator.count && buf.suffix(terminator.count) == terminator {
            return buf
        }
    }
    return nil
}

/// Request an auth cookie from iTerm2 via AppleScript. Returns (cookie, key) or nil.
private func requestiTerm2Cookie() -> (String, String)? {
    let script = NSAppleScript(source: """
        tell application "iTerm2" to request cookie and key for app named "claude-notifier"
    """)
    var error: NSDictionary?
    guard let result = script?.executeAndReturnError(&error),
          let str = result.stringValue else { return nil }
    let parts = str.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), String(parts[1]))
}

private func websocketHandshake(_ fd: Int32) -> Bool {
    var keyBytes = [UInt8](repeating: 0, count: 16)
    arc4random_buf(&keyBytes, 16)
    let key = Data(keyBytes).base64EncodedString()

    var headers = [
        "GET / HTTP/1.1",
        "Host: localhost",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: \(key)",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Protocol: api.iterm2.com",
        "Origin: ws://localhost/",
        "x-iterm2-library-version: swift 1.0",
        "x-iterm2-advisory-name: claude-notifier",
    ]
    if let (cookie, ikey) = requestiTerm2Cookie() {
        headers.append("x-iterm2-cookie: \(cookie)")
        headers.append("x-iterm2-key: \(ikey)")
    }
    let request = headers.joined(separator: "\r\n") + "\r\n\r\n"

    guard sendAll(fd, Data(request.utf8)) else { return false }
    guard let response = recvUntil(fd, Data("\r\n\r\n".utf8)) else { return false }
    let status = String(data: response, encoding: .utf8) ?? ""
    return status.contains("101")
}

private func websocketSendBinary(_ fd: Int32, _ payload: Data) -> Bool {
    var frame = Data()
    frame.append(0x82) // FIN + binary opcode
    let len = payload.count
    if len < 126 {
        frame.append(UInt8(len) | 0x80) // mask bit set
    } else {
        frame.append(126 | 0x80)
        frame.append(UInt8((len >> 8) & 0xFF))
        frame.append(UInt8(len & 0xFF))
    }
    var mask = [UInt8](repeating: 0, count: 4)
    arc4random_buf(&mask, 4)
    frame.append(contentsOf: mask)
    for (i, b) in payload.enumerated() {
        frame.append(b ^ mask[i % 4])
    }
    return sendAll(fd, frame)
}

/// Focus an iTerm2 session via its native API (WebSocket + protobuf over UDS).
/// Returns true only if the session was successfully activated (status OK).
func iterm2FocusSession(_ sessionID: String) -> Bool {
    let uuid = extractSessionUUID(sessionID)

    let path = iterm2SocketPath()
    guard FileManager.default.fileExists(atPath: path),
          let fd = connectUDS(path) else { return false }
    defer { Darwin.close(fd) }

    guard websocketHandshake(fd) else { return false }
    let msg = buildActivateSessionMessage(sessionID: uuid)
    guard websocketSendBinary(fd, msg) else { return false }

    // Check response for BAD_IDENTIFIER
    if let payload = readWebSocketPayload(fd) {
        // Look for activate_response (field 114) containing status=1 (BAD_IDENTIFIER)
        for resp in extractMessages(payload, fieldNumber: 114) {
            // status field 1, varint
            if let (status, _) = readVarint(resp, offset: 0), resp.first == 0x08, status >> 3 == 1 {
                if let (val, _) = readVarint(resp, offset: 1), val == 1 {
                    return false // BAD_IDENTIFIER
                }
            }
        }
    }
    return true
}

// -- ListSessions + tmux window matching --

private func buildListSessionsMessage() -> Data {
    // ClientOriginatedMessage { id: 2, list_sessions_request (field 106): {} }
    var msg = Data()
    msg.append(protoField(1, wireType: 0, payload: Data([0x02]))) // id = 2
    msg.append(protoField(106, wireType: 2, payload: Data()))      // empty ListSessionsRequest
    return msg
}

/// Parse a varint from data at offset. Returns (value, bytesConsumed).
private func readVarint(_ data: Data, offset: Int) -> (UInt64, Int)? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    var i = offset
    while i < data.count {
        let byte = data[i]
        result |= UInt64(byte & 0x7F) << shift
        i += 1
        if byte & 0x80 == 0 { return (result, i - offset) }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}

/// Extract the first varint value for a given field number from a protobuf message.
private func extractVarint(_ data: Data, fieldNumber: Int) -> UInt64? {
    var i = data.startIndex
    while i < data.endIndex {
        guard let (tag, tagLen) = readVarint(data, offset: i) else { break }
        let fnum = Int(tag >> 3)
        let wtype = Int(tag & 0x07)
        i += tagLen
        switch wtype {
        case 0:
            guard let (val, vLen) = readVarint(data, offset: i) else { return nil }
            if fnum == fieldNumber { return val }
            i += vLen
        case 2:
            guard let (length, lLen) = readVarint(data, offset: i) else { return nil }
            i += lLen + Int(length)
        case 1: i += 8
        case 5: i += 4
        default: return nil
        }
    }
    return nil
}

/// Extract all string values for a given field number from a protobuf message.
private func extractStrings(_ data: Data, fieldNumber: Int) -> [String] {
    var results: [String] = []
    var i = data.startIndex
    while i < data.endIndex {
        guard let (tag, tagLen) = readVarint(data, offset: i) else { break }
        let fnum = Int(tag >> 3)
        let wtype = Int(tag & 0x07)
        i += tagLen
        switch wtype {
        case 0: // varint
            guard let (_, vLen) = readVarint(data, offset: i) else { return results }
            i += vLen
        case 2: // length-delimited
            guard let (length, lLen) = readVarint(data, offset: i) else { return results }
            i += lLen
            let end = i + Int(length)
            guard end <= data.endIndex else { return results }
            if fnum == fieldNumber {
                if let s = String(data: data[i..<end], encoding: .utf8) {
                    results.append(s)
                }
            }
            i = end
        case 1: i += 8 // 64-bit
        case 5: i += 4 // 32-bit
        default: return results
        }
    }
    return results
}

/// Extract all sub-messages for a given field number.
private func extractMessages(_ data: Data, fieldNumber: Int) -> [Data] {
    var results: [Data] = []
    var i = data.startIndex
    while i < data.endIndex {
        guard let (tag, tagLen) = readVarint(data, offset: i) else { break }
        let fnum = Int(tag >> 3)
        let wtype = Int(tag & 0x07)
        i += tagLen
        switch wtype {
        case 0:
            guard let (_, vLen) = readVarint(data, offset: i) else { return results }
            i += vLen
        case 2:
            guard let (length, lLen) = readVarint(data, offset: i) else { return results }
            i += lLen
            let end = i + Int(length)
            guard end <= data.endIndex else { return results }
            if fnum == fieldNumber {
                results.append(Data(data[i..<end]))
            }
            i = end
        case 1: i += 8
        case 5: i += 4
        default: return results
        }
    }
    return results
}

/// Read a WebSocket frame payload from fd with a socket-level timeout.
private func readWebSocketPayload(_ fd: Int32, timeoutSecs: Int = 3) -> Data? {
    // Set receive timeout
    var tv = timeval(tv_sec: timeoutSecs, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Read first 2 bytes (WS frame header)
    var header = [UInt8](repeating: 0, count: 2)
    guard Darwin.read(fd, &header, 2) == 2 else { return nil }

    var payloadLen = Int(header[1] & 0x7F)
    if payloadLen == 126 {
        var ext = [UInt8](repeating: 0, count: 2)
        guard Darwin.read(fd, &ext, 2) == 2 else { return nil }
        payloadLen = (Int(ext[0]) << 8) | Int(ext[1])
    }

    // Read payload
    var payload = Data(count: payloadLen)
    var totalRead = 0
    while totalRead < payloadLen {
        let n = payload.withUnsafeMutableBytes { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress!.advanced(by: totalRead), payloadLen - totalRead)
        }
        guard n > 0 else { return nil }
        totalRead += n
    }
    return payload
}

/// Result of looking up a tmux window in ListSessions.
struct TabLookupResult {
    let tabID: String
    let tabIndex: Int      // 0-based position within window
    let windowNumber: Int  // Window.number field
    let totalWindows: Int  // total number of windows
}

/// Find the iTerm2 tab for a tmux window by querying ListSessions.
func iterm2FindTabForTmuxWindow(_ tmuxWindowID: String, fd: Int32) -> TabLookupResult? {
    let msg = buildListSessionsMessage()
    guard websocketSendBinary(fd, msg) else { return nil }
    guard let payload = readWebSocketPayload(fd) else { return nil }

    // ServerOriginatedMessage → list_sessions_response (field 106)
    guard let listResp = extractMessages(payload, fieldNumber: 106).first else { return nil }

    let windows = extractMessages(listResp, fieldNumber: 1)

    for window in windows {
        let windowNumber = Int(extractVarint(window, fieldNumber: 4) ?? 0)
        let tabs = extractMessages(window, fieldNumber: 1)
        for (tabIndex, tab) in tabs.enumerated() {
            let tmuxIds = extractStrings(tab, fieldNumber: 4)
            if tmuxIds.contains(tmuxWindowID) {
                guard let tabID = extractStrings(tab, fieldNumber: 2).first else { continue }
                return TabLookupResult(
                    tabID: tabID,
                    tabIndex: tabIndex,
                    windowNumber: windowNumber,
                    totalWindows: windows.count
                )
            }
        }
    }
    return nil
}

/// Build a keyboard shortcut string like "⌘3" from a tab lookup result. When more than one
/// iTerm2 window is open, prefix the window number (e.g. "win2 ⌘3") since ⌘N only targets the
/// key window, so the window number tells you which window to switch to first.
func shortcutString(from result: TabLookupResult) -> String? {
    let tabNum = result.tabIndex + 1
    let sc = tabNum <= 9 ? "⌘\(tabNum)" : nil
    if result.totalWindows > 1 {
        let win = "win\(result.windowNumber)"
        return sc.map { "\(win) \($0)" } ?? win
    }
    return sc
}

/// Focus an iTerm2 tmux window by looking up the tab via ListSessions, then activating it.
/// Returns the keyboard shortcut string (e.g. "⌘3") on success.
func iterm2FocusTmuxWindow(_ tmuxWindowID: String) -> String? {
    // Strip "@" prefix if present (tmux uses @N, iTerm2 API uses just N)
    let winID = tmuxWindowID.hasPrefix("@") ? String(tmuxWindowID.dropFirst()) : tmuxWindowID

    let path = iterm2SocketPath()
    guard FileManager.default.fileExists(atPath: path),
          let fd = connectUDS(path) else { return nil }
    defer { Darwin.close(fd) }

    guard websocketHandshake(fd) else { return nil }

    guard let result = iterm2FindTabForTmuxWindow(winID, fd: fd) else { return nil }

    let msg = buildActivateTabMessage(tabID: result.tabID)
    guard websocketSendBinary(fd, msg) else { return nil }
    _ = readWebSocketPayload(fd)
    return shortcutString(from: result)
}

/// Query tab position for a tmux window without activating (for notification display).
func iterm2LookupShortcut(tmuxWindowID: String) -> String? {
    let winID = tmuxWindowID.hasPrefix("@") ? String(tmuxWindowID.dropFirst()) : tmuxWindowID

    let path = iterm2SocketPath()
    guard FileManager.default.fileExists(atPath: path),
          let fd = connectUDS(path) else { return nil }
    defer { Darwin.close(fd) }

    guard websocketHandshake(fd) else { return nil }
    guard let result = iterm2FindTabForTmuxWindow(winID, fd: fd) else { return nil }
    return shortcutString(from: result)
}

/// Query both the keyboard shortcut and the iTerm tab id for a tmux window.
func iterm2LookupTab(tmuxWindowID: String) -> (shortcut: String?, tabId: String?) {
    let winID = tmuxWindowID.hasPrefix("@") ? String(tmuxWindowID.dropFirst()) : tmuxWindowID

    let path = iterm2SocketPath()
    guard FileManager.default.fileExists(atPath: path),
          let fd = connectUDS(path) else { return (nil, nil) }
    defer { Darwin.close(fd) }

    guard websocketHandshake(fd) else { return (nil, nil) }
    guard let result = iterm2FindTabForTmuxWindow(winID, fd: fd) else { return (nil, nil) }
    return (shortcutString(from: result), result.tabID)
}

// MARK: - Terminal Focus

/// Bring an app to the foreground by bundle identifier.
func activateApp(bundleID: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        // Use AppleScript as NSRunningApplication.activate is unreliable on macOS 14+
        let script = NSAppleScript(source: """
            tell application id "\(bundleID)" to activate
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}

/// Map a terminal type (from the hook's `terminal=` param) to its app bundle id and a
/// human-readable display name. iTerm2 additionally gets tab-level focus; the rest are
/// brought to the foreground at the app level.
let terminalBundleIDs: [String: String] = [
    "iterm2": "com.googlecode.iterm2",
    "vscode": "com.microsoft.VSCode",
    "terminal": "com.apple.Terminal",
    "ghostty": "com.mitchellh.ghostty",
    "wezterm": "com.github.wez.wezterm",
    "kitty": "net.kovidgoyal.kitty",
    "alacritty": "org.alacritty",
    "warp": "dev.warp.Warp-Stable",
]

let terminalDisplayNames: [String: String] = [
    "iterm2": "iTerm", "vscode": "VS Code", "terminal": "Terminal",
    "ghostty": "Ghostty", "wezterm": "WezTerm", "kitty": "kitty",
    "alacritty": "Alacritty", "warp": "Warp",
]

// MARK: - Claude Code hook commands (used by the one-command installer)

/// SessionStart hook: capture the iTerm2 session id, terminal program, tty, and tmux window id.
let sessionStartHookCommand = #"echo "$ITERM_SESSION_ID" > /tmp/claude-session-id-$PPID; echo "$TERM_PROGRAM" > /tmp/claude-term-program-$PPID; T=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' '); case "$T" in ttys*) echo "/dev/$T" > /tmp/claude-tty-$PPID;; esac; if [ -n "$TMUX" ]; then tmux display-message -p '#{window_id}' > /tmp/claude-tmux-winid-$PPID; fi"#

/// Notification hook: derive the message (recap → title → alert), status, and terminal, then
/// open the claude-notifier URL scheme. Mirrors the documented hook in README.md.
let notificationHookCommand = #"IN=$(cat) && MSG=$(echo "$IN" | jq -r '.message // "Claude Code is ready"') && NTYPE=$(echo "$IN" | jq -r '.notification_type // ""') && STATUS=$(case "$NTYPE" in (permission_prompt) echo review;; (idle_prompt) echo waiting;; (auth_success) echo done;; (*) echo review;; esac) && TRANSCRIPT=$(echo "$IN" | jq -r '.transcript_path // ""') && AWAY=$(cat "$TRANSCRIPT" 2>/dev/null | jq -rs '([.[] | select(.type=="system" and .subtype=="away_summary") | .content] | last // "") | .[0:1000]' 2>/dev/null | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') && TITLE=$(cat "$TRANSCRIPT" 2>/dev/null | jq -rs '[.[] | select(.type=="ai-title") | .aiTitle] | last // ""' 2>/dev/null | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') && SRC=alert && if [ -n "$AWAY" ]; then MSG="$AWAY"; SRC=recap; elif [ -n "$TITLE" ]; then MSG="$TITLE"; SRC=title; fi && SID=$(cat /tmp/claude-session-id-$PPID 2>/dev/null || echo '') && TWID=$(cat /tmp/claude-tmux-winid-$PPID 2>/dev/null || echo '') && TTY=$(cat /tmp/claude-tty-$PPID 2>/dev/null || echo '') && TPROG=$(cat /tmp/claude-term-program-$PPID 2>/dev/null || echo "$TERM_PROGRAM") && TAPP=$(case "$TPROG" in (iTerm.app) echo iterm2;; (Apple_Terminal) echo terminal;; (vscode) echo vscode;; (ghostty) echo ghostty;; (WezTerm) echo wezterm;; (WarpTerminal) echo warp;; (*) echo unknown;; esac) && PROJECT=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")") && MSG_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$MSG") && TITLE_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PROJECT") && TWID_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TWID") && TTY_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TTY") && open -g "claude-notifier://notify?title=$TITLE_ENC&message=$MSG_ENC&terminal=$TAPP&session=$SID&tmux_window_id=$TWID_ENC&tty=$TTY_ENC&status=$STATUS&source=$SRC""#

/// Optional PreToolUse approval hook (matcher: Bash). A no-op unless Remote Approvals is on
/// (the flag file exists), in which case it notifies, waits up to ~60s for an Approve/Deny from
/// the inbox, and returns the matching permissionDecision; on timeout it defers to the normal prompt.
let approvalHookCommand = ##"[ -f /tmp/claude-notifier-remote-approvals ] || exit 0; IN=$(cat); TOOL=$(echo "$IN" | jq -r '.tool_name // "Bash"'); CMD=$(echo "$IN" | jq -r '.tool_input.command // .tool_input.file_path // ""' | tr '\n' ' ' | cut -c1-200); REQ="$PPID-$$-$(date +%s)"; SID=$(cat /tmp/claude-session-id-$PPID 2>/dev/null || echo ''); TWID=$(cat /tmp/claude-tmux-winid-$PPID 2>/dev/null || echo ''); TTY=$(cat /tmp/claude-tty-$PPID 2>/dev/null || echo ''); TPROG=$(cat /tmp/claude-term-program-$PPID 2>/dev/null || echo "$TERM_PROGRAM"); TAPP=$(case "$TPROG" in (iTerm.app) echo iterm2;; (Apple_Terminal) echo terminal;; (vscode) echo vscode;; (ghostty) echo ghostty;; (WezTerm) echo wezterm;; (WarpTerminal) echo warp;; (*) echo unknown;; esac); PROJECT=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"); ENC(){ python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }; rm -f "/tmp/claude-notifier-decision-$REQ.json"; open -g "claude-notifier://notify?title=$(ENC "$PROJECT")&message=$(ENC "$TOOL: $CMD")&terminal=$TAPP&session=$SID&tmux_window_id=$(ENC "$TWID")&tty=$(ENC "$TTY")&status=review&tool=$(ENC "$TOOL")&decision=$REQ"; D=""; for i in $(seq 1 120); do if [ -f "/tmp/claude-notifier-decision-$REQ.json" ]; then D=$(jq -r '.decision // ""' "/tmp/claude-notifier-decision-$REQ.json" 2>/dev/null); rm -f "/tmp/claude-notifier-decision-$REQ.json"; break; fi; sleep 0.5; done; [ "$D" = "allow" ] && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved in claude-notifier"}}'; [ "$D" = "deny" ] && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied in claude-notifier"}}'; exit 0"##

func focusTerminal(terminalType: String, itermSession: String?, tmuxWindowID: String?,
                   bundle: String? = nil, tty: String? = nil) {
    if terminalType == "iterm2" {
        // 1) tmux integration → ListSessions to find matching tab, then Activate
        if let twID = tmuxWindowID, !twID.isEmpty, iterm2FocusTmuxWindow(twID) != nil {
            activateApp(bundleID: "com.googlecode.iterm2")
            return
        }
        // 2) Native session → direct ActivateRequest
        if let session = itermSession, !session.isEmpty, iterm2FocusSession(session) {
            activateApp(bundleID: "com.googlecode.iterm2")
            return
        }
        // 3) Fallback: just activate iTerm2
        activateApp(bundleID: "com.googlecode.iterm2")
        return
    }
    // Terminal.app: focus the specific tab by its controlling tty when known.
    if terminalType == "terminal", let tty = tty, !tty.isEmpty {
        focusTerminalAppTab(tty: tty)
        return
    }
    // Everything else: app-level activation by bundle id (tab focus is iTerm2/Terminal.app-only).
    if let b = bundle ?? terminalBundleIDs[terminalType] {
        activateApp(bundleID: b)
    }
}

/// Select the Terminal.app tab whose controlling tty matches, then bring Terminal.app forward.
/// First use triggers a one-time macOS automation (TCC) permission prompt for Terminal control.
func focusTerminalAppTab(tty: String) {
    let script = """
    tell application "Terminal"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                try
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end try
            end repeat
        end repeat
    end tell
    """
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let s = NSAppleScript(source: script)
        var err: NSDictionary?
        s?.executeAndReturnError(&err)
    }
}

// MARK: - iTerm2 active-session monitor (auto-dismiss on tab focus)

private func buildFocusRequestMessage(id: UInt64) -> Data {
    var msg = Data()
    msg.append(protoField(1, wireType: 0, payload: protoVarint(id)))   // id
    msg.append(protoField(117, wireType: 2, payload: Data()))          // focus_request {}
    return msg
}

private func buildSubscribeFocusMessage(id: UInt64) -> Data {
    var req = Data()
    req.append(protoField(1, wireType: 2, payload: Data("all".utf8)))  // session = "all"
    req.append(protoField(2, wireType: 0, payload: Data([0x01])))      // subscribe = true
    req.append(protoField(3, wireType: 0, payload: protoVarint(9)))    // notification_type = NOTIFY_ON_FOCUS_CHANGE
    var msg = Data()
    msg.append(protoField(1, wireType: 0, payload: protoVarint(id)))   // id
    msg.append(protoField(103, wireType: 2, payload: req))             // notification_request
    return msg
}

private let focusDebug = ProcessInfo.processInfo.environment["CLAUDE_NOTIFIER_FOCUS_DEBUG"] != nil

private func focusLog(_ s: String) {
    guard focusDebug else { return }
    guard let data = (s + "\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/claude-notifier-focus.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: url)
    }
}

/// Long-lived connection to iTerm2 that subscribes to focus-change notifications,
/// so the app learns which session/tab is active without the user clicking the pet.
final class FocusMonitor {
    var onActiveSession: ((String) -> Void)?
    var onActiveTab: ((String) -> Void)?
    /// Fired (on the main thread) when the iTerm2 subscription connects or drops, so the UI can
    /// show a health dot. Only meaningful when iTerm2 is in use.
    var onHealthChange: ((Bool) -> Void)?
    private(set) var connected = false {
        didSet {
            guard connected != oldValue else { return }
            let c = connected
            DispatchQueue.main.async { [weak self] in self?.onHealthChange?(c) }
        }
    }

    private var running = false
    private var reqId: UInt64 = 1000

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    private func loop() {
        while running {
            monitorOnce()
            if running { Thread.sleep(forTimeInterval: 3) } // reconnect backoff
        }
    }

    private func monitorOnce() {
        let path = iterm2SocketPath()
        guard FileManager.default.fileExists(atPath: path), let fd = connectUDS(path) else { return }
        defer { Darwin.close(fd); connected = false }
        guard websocketHandshake(fd) else { return }

        reqId += 1; _ = websocketSendBinary(fd, buildSubscribeFocusMessage(id: reqId))
        reqId += 1; _ = websocketSendBinary(fd, buildFocusRequestMessage(id: reqId))
        connected = true
        focusLog("monitor: connected & subscribed")

        while running {
            guard let frame = readFrame(fd) else { focusLog("monitor: read nil → reconnect"); return }
            if frame.isEmpty { continue } // control frame (ping/pong)
            process(frame)
        }
    }

    private func readN(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var got = 0
        while got < n {
            let r = Darwin.read(fd, &buf[got], n - got)
            guard r > 0 else { return false }
            got += r
        }
        return true
    }

    /// Read one WebSocket frame, handling control frames and 16/64-bit lengths.
    private func readFrame(_ fd: Int32) -> Data? {
        var hdr = [UInt8](repeating: 0, count: 2)
        guard readN(fd, &hdr, 2) else { return nil }
        let opcode = hdr[0] & 0x0F
        var len = Int(hdr[1] & 0x7F)
        if len == 126 {
            var e = [UInt8](repeating: 0, count: 2)
            guard readN(fd, &e, 2) else { return nil }
            len = (Int(e[0]) << 8) | Int(e[1])
        } else if len == 127 {
            var e = [UInt8](repeating: 0, count: 8)
            guard readN(fd, &e, 8) else { return nil }
            len = 0; for b in e { len = (len << 8) | Int(b) }
        }
        var payload = [UInt8](repeating: 0, count: max(len, 1))
        if len > 0 { guard readN(fd, &payload, len) else { return nil } }
        switch opcode {
        case 0x8: return nil          // close
        case 0x9:                     // ping → reply with pong so the server keeps us alive
            sendPong(fd, Array(payload.prefix(len)))
            return Data()
        case 0xA: return Data()       // pong → ignore
        default: return len > 0 ? Data(payload[0..<len]) : Data()
        }
    }

    private func sendPong(_ fd: Int32, _ data: [UInt8]) {
        var frame = Data([0x8A]) // FIN + pong opcode
        let l = data.count
        if l < 126 {
            frame.append(UInt8(l) | 0x80) // mask bit
        } else {
            frame.append(126 | 0x80)
            frame.append(UInt8((l >> 8) & 0xFF))
            frame.append(UInt8(l & 0xFF))
        }
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, 4)
        frame.append(contentsOf: mask)
        for (i, b) in data.enumerated() { frame.append(b ^ mask[i % 4]) }
        _ = sendAll(fd, frame)
    }

    private func process(_ payload: Data) {
        // focus_response (117) → FocusResponse.notifications (1)
        for fr in extractMessages(payload, fieldNumber: 117) {
            for fc in extractMessages(fr, fieldNumber: 1) { applyFocus(fc) }
        }
        // pushed notification (1000) → Notification.focus_changed_notification (9)
        for notif in extractMessages(payload, fieldNumber: 1000) {
            for fc in extractMessages(notif, fieldNumber: 9) { applyFocus(fc) }
        }
    }

    private func applyFocus(_ fc: Data) {
        if let session = extractStrings(fc, fieldNumber: 4).first, !session.isEmpty {
            focusLog("active session: \(session)")
            DispatchQueue.main.async { [weak self] in self?.onActiveSession?(session) }
        }
        if let tab = extractStrings(fc, fieldNumber: 3).first, !tab.isEmpty {
            focusLog("active tab: \(tab)")
            DispatchQueue.main.async { [weak self] in self?.onActiveTab?(tab) }
        }
    }
}

// MARK: - Launch at Login

func isLaunchAtLoginEnabled() -> Bool {
    if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
    }
    return false
}

func setLaunchAtLogin(_ enabled: Bool) {
    if #available(macOS 13.0, *) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail — user can toggle again
        }
    }
}

// MARK: - Notification Inbox

let defaultsKeyBannerEnabled = "bannerEnabled" // legacy bool, migrated to bannerMode
let defaultsKeyBannerMode = "bannerMode"        // "off" | "transient" | "persist"
let defaultsKeyAlwaysOnTop = "alwaysOnTop"
let defaultsKeyCompactRows = "compactRows"      // truncate each row's message to one line
let defaultsKeyQuietEnabled = "quietHoursEnabled"
let defaultsKeyQuietStart = "quietHoursStart"   // minutes from midnight
let defaultsKeyQuietEnd = "quietHoursEnd"       // minutes from midnight
let defaultsKeyPauseUntil = "pauseUntil"        // unix time; notifications muted until then
let defaultsKeyEscalateMinutes = "escalateMinutes" // 0 = off; else re-alert an unread item once after N min
let defaultsKeyWebhookURL = "webhookURL"        // optional HTTPS endpoint to forward notifications to
let defaultsKeyRemoteApprovals = "remoteApprovals" // route Bash permission prompts to the inbox

/// Flag file the PreToolUse approval hook checks: present only while Remote Approvals is on,
/// so the hook is a zero-cost no-op otherwise.
let remoteApprovalsFlagPath = "/tmp/claude-notifier-remote-approvals"

/// How the native macOS banner behaves. Defaults to "transient" so the banner is a
/// fleeting arrival cue and does not pile up in Notification Center (the in-app inbox is
/// the persistent record). Migrates the old on/off `bannerEnabled` bool on first read.
func currentBannerMode() -> String {
    let d = UserDefaults.standard
    if let m = d.string(forKey: defaultsKeyBannerMode) { return m }
    if d.object(forKey: defaultsKeyBannerEnabled) != nil {
        return d.bool(forKey: defaultsKeyBannerEnabled) ? "transient" : "off"
    }
    return "transient"
}

/// Whether banners/sounds are currently muted by a manual pause or the quiet-hours window.
/// The inbox still collects notifications; only the banner and sound are suppressed.
func isQuietNow() -> Bool {
    let d = UserDefaults.standard
    let pause = d.double(forKey: defaultsKeyPauseUntil)
    if pause > 0, Date().timeIntervalSince1970 < pause { return true }
    guard d.bool(forKey: defaultsKeyQuietEnabled) else { return false }
    let cal = Calendar.current
    let now = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
    let start = d.object(forKey: defaultsKeyQuietStart) != nil ? d.integer(forKey: defaultsKeyQuietStart) : 22 * 60
    let end = d.object(forKey: defaultsKeyQuietEnd) != nil ? d.integer(forKey: defaultsKeyQuietEnd) : 8 * 60
    if start == end { return false }
    if start < end { return now >= start && now < end }
    return now >= start || now < end // window wraps past midnight
}

/// Semantic task state carried by the `status` URL param. Drives the row's status dot.
enum NotifStatus: String, Codable, CaseIterable {
    case running, waiting, review, done, failed, message

    init(param: String?) {
        switch (param ?? "").lowercased() {
        case "running", "progress", "working":                 self = .running
        case "waiting", "paused", "idle":                      self = .waiting
        case "review", "attention", "input", "permission":     self = .review
        case "done", "success", "completed", "complete", "ok": self = .done
        case "failed", "error", "failure", "blocked":          self = .failed
        case "message", "info", "note":                        self = .message
        // The Notification hook fires when Claude needs you, so default to "come back".
        default:                                               self = .review
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .review:  return "Needs you"
        case .done:    return "Done"
        case .failed:  return "Failed"
        case .message: return "Message"
        }
    }

    /// Color of the status dot shown at the start of each row.
    var color: NSColor {
        switch self {
        case .running: return NSColor(calibratedRed: 0.13, green: 0.43, blue: 0.69, alpha: 1)
        case .waiting: return NSColor(calibratedRed: 0.38, green: 0.42, blue: 0.50, alpha: 1)
        case .review:  return NSColor(calibratedRed: 0.85, green: 0.46, blue: 0.05, alpha: 1)
        case .done:    return NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.27, alpha: 1)
        case .failed:  return NSColor(calibratedRed: 0.74, green: 0.20, blue: 0.24, alpha: 1)
        case .message: return NSColor(calibratedRed: 0.44, green: 0.35, blue: 0.71, alpha: 1)
        }
    }

    /// Distinct sound used when "Per-Status Sound" is enabled, so you can tell what happened
    /// without looking (a failure sounds different from a completion).
    var defaultSound: String {
        switch self {
        case .running: return "Pop"
        case .waiting: return "Submarine"
        case .review:  return "Ping"
        case .done:    return "Glass"
        case .failed:  return "Basso"
        case .message: return "Tink"
        }
    }
}

/// Short relative time like "now", "5m", "2h", "3d".
func relativeTimeString(_ date: Date) -> String {
    let s = Int(max(0, Date().timeIntervalSince(date)))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}

/// One delivered notification, retained in the inbox until acted on or dismissed.
/// Codable so the inbox can be persisted to disk and restored across restarts. The custom
/// decoder is tolerant of missing keys (defaults applied) so adding a field in a future
/// release never invalidates an existing on-disk inbox.
struct NotificationItem: Codable {
    let id: String            // dedup key: tmux window id ?? session ?? uuid
    let sessionUUID: String?  // normalized bare iTerm session UUID (non-tmux focus match)
    let tabId: String?        // resolved iTerm tab id (tmux focus match)
    let terminal: String      // raw terminal type, passed to focusTerminal()
    let terminalName: String? // display name: "iTerm" / "VS Code" / "Terminal"
    let rawSession: String?   // raw ITERM_SESSION_ID, passed to focusTerminal()
    let tmux: String?         // tmux window id, passed to focusTerminal()
    let shortcut: String?     // iTerm tab shortcut like "⌘3"
    var title: String         // project name
    var message: String
    var status: NotifStatus
    var date: Date
    var read: Bool            // false = pending (unread); true = acted/auto-read history
    var count: Int = 1        // how many times this tab has notified (shown as ×N when > 1)
    var source: String? = nil // which message source the hook used: recap / title / alert
    var bundle: String? = nil // resolved app bundle id, for focusing non-iTerm terminals
    var escalated: Bool = false // a one-time re-alert has already fired for this unread item
    var tool: String? = nil   // tool that triggered the prompt (e.g. "Bash"), if the hook sent it
    var tty: String? = nil    // controlling tty (e.g. /dev/ttys004), for Terminal.app tab focus
    var decision: String? = nil // pending approval request id; row shows Approve/Deny while unread

    init(id: String, sessionUUID: String?, tabId: String?, terminal: String,
         terminalName: String?, rawSession: String?, tmux: String?, shortcut: String?,
         title: String, message: String, status: NotifStatus, date: Date, read: Bool,
         count: Int = 1, source: String? = nil, bundle: String? = nil, escalated: Bool = false,
         tool: String? = nil, tty: String? = nil, decision: String? = nil) {
        self.id = id; self.sessionUUID = sessionUUID; self.tabId = tabId
        self.terminal = terminal; self.terminalName = terminalName
        self.rawSession = rawSession; self.tmux = tmux; self.shortcut = shortcut
        self.title = title; self.message = message; self.status = status
        self.date = date; self.read = read; self.count = count
        self.source = source; self.bundle = bundle; self.escalated = escalated
        self.tool = tool; self.tty = tty; self.decision = decision
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionUUID, tabId, terminal, terminalName, rawSession, tmux, shortcut
        case title, message, status, date, read, count, source, bundle, escalated, tool, tty, decision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionUUID = try c.decodeIfPresent(String.self, forKey: .sessionUUID)
        tabId = try c.decodeIfPresent(String.self, forKey: .tabId)
        terminal = (try c.decodeIfPresent(String.self, forKey: .terminal)) ?? "unknown"
        terminalName = try c.decodeIfPresent(String.self, forKey: .terminalName)
        rawSession = try c.decodeIfPresent(String.self, forKey: .rawSession)
        tmux = try c.decodeIfPresent(String.self, forKey: .tmux)
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        message = (try c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        status = (try c.decodeIfPresent(NotifStatus.self, forKey: .status)) ?? .review
        date = (try c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        read = (try c.decodeIfPresent(Bool.self, forKey: .read)) ?? true
        count = (try c.decodeIfPresent(Int.self, forKey: .count)) ?? 1
        source = try c.decodeIfPresent(String.self, forKey: .source)
        bundle = try c.decodeIfPresent(String.self, forKey: .bundle)
        escalated = (try c.decodeIfPresent(Bool.self, forKey: .escalated)) ?? false
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        tty = try c.decodeIfPresent(String.self, forKey: .tty)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
    }
}

/// In-memory inbox. Newest item first. `onChange` fires after any mutation.
/// All callers run on the main thread (URL open + FocusMonitor callbacks are
/// dispatched to main), so no locking is needed.
final class NotificationStore {
    private(set) var items: [NotificationItem] = []
    var onChange: (() -> Void)?
    private let maxItems = 50
    private var saveWork: DispatchWorkItem?

    var unreadCount: Int { items.reduce(0) { $0 + ($1.read ? 0 : 1) } }

    /// Notify observers and schedule a debounced disk save after any mutation.
    private func changed() {
        onChange?()
        scheduleSave()
    }

    /// Add a notification, or refresh the existing one for the same tab (dedup by id).
    /// `forceRead` lands the item silently as read history (used when the user is already
    /// looking at the originating tab), and keeps a dedup'd row read instead of re-flagging it.
    func add(_ item: NotificationItem, forceRead: Bool = false) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            // Same tab notified again: replace the whole entry (so freshly resolved
            // routing metadata like tabId/shortcut wins), float to top, and bump the repeat
            // count so stacked notifications are visible as ×N.
            var updated = item
            // Reset the stack count once the row was read/acknowledged; otherwise keep
            // counting the current unread streak.
            updated.count = items[i].read ? 1 : items[i].count + 1
            updated.read = forceRead
            // A fresh unread ping should be eligible to re-alert again; a silent (forceRead)
            // refresh keeps whatever escalation state the row already had.
            updated.escalated = forceRead ? items[i].escalated : false
            items.remove(at: i)
            items.insert(updated, at: 0)
        } else {
            var newItem = item
            if forceRead { newItem.read = true }
            items.insert(newItem, at: 0)
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
        }
        changed()
    }

    func markRead(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
        changed()
    }

    /// The user switched to an iTerm session: auto-read its pending notification.
    func markReadByActiveSession(_ sessionID: String) {
        let uuid = extractSessionUUID(sessionID)
        var didChange = false
        for i in items.indices where !items[i].read && items[i].sessionUUID == uuid {
            items[i].read = true; didChange = true
        }
        if didChange { changed() }
    }

    /// The user switched to an iTerm tab: auto-read pending notifications bound to it.
    func markReadByActiveTab(_ tabId: String) {
        var didChange = false
        for i in items.indices where !items[i].read && items[i].tabId == tabId {
            items[i].read = true; didChange = true
        }
        if didChange { changed() }
    }

    /// Mark a row as having already fired its one-time re-alert (no UI change, persisted quietly).
    func markEscalated(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].escalated else { return }
        items[i].escalated = true
        scheduleSave()
    }

    func remove(id: String) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { changed() }
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        changed()
    }

    // MARK: Persistence

    private static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("claude-notifier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inbox.json")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Write the inbox to disk now (atomic). Called on a debounce, and synchronously on quit
    /// so the very crash/quit we want to survive doesn't drop the last few notifications.
    func flush() {
        saveWork?.cancel(); saveWork = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: Self.fileURL(), options: .atomic)
    }

    /// Restore the inbox from disk. A decode failure moves the bad file aside and starts clean.
    func load() {
        let url = Self.fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let restored = try? dec.decode([NotificationItem].self, from: data) {
            items = restored
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
            onChange?()
        } else {
            let stamp = Int(Date().timeIntervalSince1970)
            let bad = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: bad)
        }
    }
}

// MARK: - Inbox UI

/// Top-left origin container so the row list grows downward inside the scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One row in the inbox list. Clicking the row focuses the terminal; the × dismisses.
final class NotificationRowView: NSView {
    let id: String
    var onSelect: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onDecision: ((String, String) -> Void)?  // (id, "allow"|"deny")
    /// Keyboard-navigation selection highlight.
    var selected = false { didSet { if selected != oldValue { updateBackground() } } }

    private let compact: Bool
    private let dismissButton = NSButton()
    private var approveButton: NSButton?
    private var denyButton: NSButton?
    private var hovered = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    init(item: NotificationItem, width: CGFloat, compact: Bool) {
        self.id = item.id
        self.compact = compact
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build(item: item, width: width)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build(item: NotificationItem, width: CGFloat) {
        let dimmed = item.read

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (dimmed ? item.status.color.withAlphaComponent(0.35)
                                             : item.status.color).cgColor
        dot.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        let dotHolder = NSView()
        dotHolder.translatesAutoresizingMaskIntoConstraints = false
        dotHolder.addSubview(dot)
        NSLayoutConstraint.activate([
            dotHolder.widthAnchor.constraint(equalToConstant: 8),
            dot.topAnchor.constraint(equalTo: dotHolder.topAnchor, constant: 3),
            dot.centerXAnchor.constraint(equalTo: dotHolder.centerXAnchor),
        ])
        dotHolder.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.textColor = dimmed ? .tertiaryLabelColor : .labelColor
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var metaParts: [String] = []
        if let src = item.source, !src.isEmpty { metaParts.append(src) }
        if let sc = item.shortcut { metaParts.append(sc) }
        if let tn = item.terminalName { metaParts.append(tn) }
        if let tl = item.tool, !tl.isEmpty { metaParts.append(tl) }
        metaParts.append(relativeTimeString(item.date))
        let meta = NSTextField(labelWithString: metaParts.joined(separator: " · "))
        meta.font = .systemFont(ofSize: 10)
        meta.textColor = .tertiaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.maximumNumberOfLines = 1
        meta.setContentHuggingPriority(.required, for: .horizontal)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)

        var titleViews: [NSView] = [title]
        // Show the ×N stack count only while unread; reading the row clears it.
        if item.count > 1 && !dimmed {
            titleViews.append(makeCountBadge(item.count, color: item.status.color))
        }
        titleViews.append(meta)
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.distribution = .fill

        let message = NSTextField(wrappingLabelWithString: item.message)
        message.font = .systemFont(ofSize: 11)
        message.textColor = dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        // Compact mode truncates to one line; expanded (default) grows the row to fit.
        message.maximumNumberOfLines = compact ? 1 : 0
        message.lineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
        message.preferredMaxLayoutWidth = max(120, width - 64)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.isHidden = item.message.isEmpty

        var colViews: [NSView] = [titleRow]
        if !item.message.isEmpty { colViews.append(message) }
        // Pending approval request: show Approve / Deny while the row is unread.
        if item.decision != nil && !item.read {
            let approve = NSButton(title: "Approve", target: self, action: #selector(approveClicked))
            let deny = NSButton(title: "Deny", target: self, action: #selector(denyClicked))
            for b in [approve, deny] {
                b.controlSize = .small
                b.bezelStyle = .rounded
                b.font = .systemFont(ofSize: 11)
                b.setContentHuggingPriority(.required, for: .horizontal)
            }
            approveButton = approve
            denyButton = deny
            let btnRow = NSStackView(views: [approve, deny])
            btnRow.orientation = .horizontal
            btnRow.spacing = 8
            colViews.append(btnRow)
        }
        let textCol = NSStackView(views: colViews)
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.isBordered = false
        dismissButton.bezelStyle = .inline
        dismissButton.title = "✕"
        dismissButton.font = .systemFont(ofSize: 11)
        dismissButton.contentTintColor = .tertiaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The × is pinned to the top-right corner; the content fills the space before it,
        // so the dismiss column stays aligned across rows regardless of text length.
        let row = NSStackView(views: [dotHolder, textCol])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dismissButton)
        addSubview(row)
        NSLayoutConstraint.activate([
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @objc private func dismissClicked() { onDismiss?(id) }
    @objc private func approveClicked() { onDecision?(id, "allow") }
    @objc private func denyClicked() { onDecision?(id, "deny") }

    /// A small rounded "×N" pill marking how many times this tab has notified.
    private func makeCountBadge(_ count: Int, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        container.layer?.cornerRadius = 7
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "×\(count)")
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 14),
        ])
        return container
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBackground() }

    private func updateBackground() {
        let color: NSColor
        if selected {
            color = NSColor.controlAccentColor.withAlphaComponent(0.20)
        } else if hovered {
            color = NSColor.labelColor.withAlphaComponent(0.06)
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    // Route clicks: × → the dismiss button, everything else → this row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        let pInSelf = convert(point, from: sv)
        guard bounds.contains(pInSelf) else { return nil }
        let pInBtn = dismissButton.convert(pInSelf, from: self)
        if dismissButton.bounds.contains(pInBtn) { return dismissButton }
        // Let the Approve/Deny buttons receive their own clicks instead of the row.
        for b in [approveButton, denyButton].compactMap({ $0 }) {
            let p = b.convert(pInSelf, from: self)
            if b.bounds.contains(p) { return b }
        }
        return self
    }

    // Act on the very first click even when the window is inactive (common with Always on
    // Top, where the window floats but keyboard focus stays in the terminal). Without this,
    // the first click would only activate the window and the notification wouldn't open.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        // Claim the event so mouseUp is delivered here, even if the list rebuilds in between.
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        // AppKit delivers mouseUp to whichever view got mouseDown, so honor the press
        // regardless of where the cursor ends up (a tiny drag should still count).
        if pressed { pressed = false; onSelect?(id) }
    }
}

/// Root view that forwards key presses, so the inbox supports arrow-key navigation when the
/// list (not the search field) holds focus.
final class InboxRootView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// The inbox content view: a header (unread count, clear-all, settings gear), a search/filter
/// bar, then a scrollable list of notification rows (or an empty-state label). Hosted in the
/// main window (set as the window's contentViewController).
final class InboxViewController: NSViewController, NSSearchFieldDelegate {
    private let store: NotificationStore
    var onSelect: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onClearAll: (() -> Void)?
    var onSettings: ((NSView) -> Void)?
    var onDecision: ((String, String) -> Void)?

    /// iTerm2 focus-monitor connection health (set by the app delegate).
    var iterm2Connected = false

    private let contentWidth: CGFloat = 380
    private let headerHeight: CGFloat = 38

    private let healthDot = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let docView = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "No notifications")

    // Live search / status filter and keyboard-selection state.
    private var searchText = ""
    private var statusFilter: NotifStatus?
    private var selectedId: String?
    private var displayed: [NotificationItem] = []
    private var rowViews: [NotificationRowView] = []

    init(store: NotificationStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = InboxRootView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 480))
        root.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        // --- Header ---
        healthDot.translatesAutoresizingMaskIntoConstraints = false
        healthDot.wantsLayer = true
        healthDot.layer?.cornerRadius = 4
        healthDot.isHidden = true
        healthDot.toolTip = "iTerm2 focus connection"
        NSLayoutConstraint.activate([
            healthDot.widthAnchor.constraint(equalToConstant: 8),
            healthDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        clearButton.title = "Clear all"
        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.contentTintColor = .controlAccentColor
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        let gear = NSButton()
        gear.isBordered = false
        gear.bezelStyle = .inline
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") {
            gear.image = img
        } else {
            gear.title = "⚙"
        }
        gear.target = self
        gear.action = #selector(settingsClicked(_:))
        gear.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [healthDot, countLabel, spacer, clearButton, gear])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        // --- Search / filter bar ---
        searchField.placeholderString = "Search"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        filterPopup.controlSize = .small
        filterPopup.font = .systemFont(ofSize: 11)
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged(_:))
        filterPopup.setContentHuggingPriority(.required, for: .horizontal)
        rebuildFilterPopup()

        let filterBar = NSStackView(views: [searchField, filterPopup])
        filterBar.orientation = .horizontal
        filterBar.spacing = 8
        filterBar.alignment = .centerY
        filterBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(filterBar)

        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator2)

        // --- Scrollable list ---
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(listStack)
        scrollView.documentView = docView
        root.addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),

            filterBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: separator.bottomAnchor),

            separator2.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator2.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator2.topAnchor.constraint(equalTo: filterBar.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator2.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            docView.topAnchor.constraint(equalTo: clip.topAnchor),
            docView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            docView.widthAnchor.constraint(equalTo: clip.widthAnchor),

            listStack.topAnchor.constraint(equalTo: docView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        self.view = root
    }

    private func rebuildFilterPopup() {
        filterPopup.removeAllItems()
        filterPopup.addItem(withTitle: "All")
        filterPopup.lastItem?.representedObject = nil
        for status in NotifStatus.allCases {
            filterPopup.addItem(withTitle: status.label)
            filterPopup.lastItem?.representedObject = status.rawValue
        }
    }

    @objc private func clearClicked() { onClearAll?() }
    @objc private func settingsClicked(_ sender: NSButton) { onSettings?(sender) }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String {
            statusFilter = NotifStatus(rawValue: raw)
        } else {
            statusFilter = nil
        }
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchText = searchField.stringValue
        refresh()
    }

    /// Rebuild the row list from the store, applying the active search/status filter.
    func refresh() {
        loadViewIfNeeded()

        // Preserve scroll position across the full rebuild (e.g. an auto-read while the
        // user is scrolled down should not yank the list back to the top).
        let savedScroll = scrollView.contentView.bounds.origin

        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()

        displayed = filteredItems()
        let total = store.items.count
        let unread = store.unreadCount

        // Health dot: shown only when iTerm2's socket is present (i.e. iTerm2 is in use).
        let socketExists = FileManager.default.fileExists(atPath: iterm2SocketPath())
        healthDot.isHidden = !socketExists
        healthDot.layer?.backgroundColor = (iterm2Connected ? NSColor.systemGreen : NSColor.systemRed)
            .withAlphaComponent(0.8).cgColor
        healthDot.toolTip = iterm2Connected ? "iTerm2 focus connection: connected"
                                            : "iTerm2 focus connection: disconnected"

        let base = unread > 0 ? "\(unread) pending" : (total == 0 ? "" : "all read")
        var label = isQuietNow() ? "🌙 " + (base.isEmpty ? "Do Not Disturb" : base) : base
        if !searchText.isEmpty || statusFilter != nil {
            label = "\(displayed.count)/\(total)" + (label.isEmpty ? "" : " · \(label)")
        }
        countLabel.stringValue = label

        clearButton.isHidden = total == 0
        emptyLabel.stringValue = total == 0 ? "No notifications" : "No matches"
        emptyLabel.isHidden = !displayed.isEmpty
        scrollView.isHidden = displayed.isEmpty

        // Drop a stale selection that the filter no longer shows.
        if let sel = selectedId, !displayed.contains(where: { $0.id == sel }) { selectedId = nil }

        let compact = UserDefaults.standard.bool(forKey: defaultsKeyCompactRows)
        for (idx, item) in displayed.enumerated() {
            let row = NotificationRowView(item: item, width: contentWidth, compact: compact)
            row.onSelect = { [weak self] id in self?.onSelect?(id) }
            row.onDismiss = { [weak self] id in self?.onDismiss?(id) }
            row.onDecision = { [weak self] id, d in self?.onDecision?(id, d) }
            row.selected = (item.id == selectedId)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rowViews.append(row)
            if idx < displayed.count - 1 {
                let div = NSBox()
                div.boxType = .separator
                div.translatesAutoresizingMaskIntoConstraints = false
                listStack.addArrangedSubview(div)
                div.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }

        view.layoutSubtreeIfNeeded()
        let maxY = max(0, docView.frame.height - scrollView.contentView.bounds.height)
        let clampedY = min(max(0, savedScroll.y), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: savedScroll.x, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func filteredItems() -> [NotificationItem] {
        let q = searchText.lowercased()
        return store.items.filter { item in
            if let f = statusFilter, item.status != f { return false }
            if !q.isEmpty,
               !item.title.lowercased().contains(q),
               !item.message.lowercased().contains(q) { return false }
            return true
        }
    }

    /// Make the list the first responder so arrow keys navigate (called when the window opens).
    func focusList() { view.window?.makeFirstResponder(view) }

    // MARK: Keyboard navigation

    /// Returns true if the key was handled. ↑/↓ move the selection, Return opens it, Delete dismisses.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !displayed.isEmpty else { return false }
        let cur = selectedId.flatMap { sel in displayed.firstIndex(where: { $0.id == sel }) }
        switch event.keyCode {
        case 125: select(index: min((cur.map { $0 + 1 } ?? 0), displayed.count - 1)); return true // ↓
        case 126: select(index: max((cur.map { $0 - 1 } ?? 0), 0)); return true                    // ↑
        case 36, 76: if let sel = selectedId { onSelect?(sel) }; return true                        // ⏎
        case 51, 117: if let sel = selectedId { onDismiss?(sel) }; return true                      // ⌫
        default: return false
        }
    }

    private func select(index: Int) {
        guard displayed.indices.contains(index) else { return }
        selectedId = displayed[index].id
        for (i, row) in rowViews.enumerated() { row.selected = (i == index) }
        if rowViews.indices.contains(index) { rowViews[index].scrollToVisible(rowViews[index].bounds) }
    }
}

// MARK: - Notification Delegate

class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    /// Called when the user clicks a native banner: (inbox id, terminal, session, tmux, bundle, tty).
    var onActivate: ((String?, String, String?, String?, String?, String?) -> Void)?

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        return true
    }

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        center.removeDeliveredNotification(notification)
        let userInfo = notification.userInfo ?? [:]
        onActivate?(
            notification.identifier,
            userInfo["terminalType"] as? String ?? "unknown",
            userInfo["itermSession"] as? String,
            userInfo["tmuxWindowID"] as? String,
            userInfo["bundle"] as? String,
            userInfo["tty"] as? String
        )
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let notificationDelegate = NotificationDelegate()
    let store = NotificationStore()
    let focusMonitor = FocusMonitor()
    var window: NSWindow!
    var inboxVC: InboxViewController!

    private var settingsMenu: NSMenu!
    private var notificationsMenu: NSMenu!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var hasAutoShownWindow = false

    // Last-known active iTerm2 session/tab (from FocusMonitor), used to silence a banner/sound
    // when a notification fires for the tab the user is already looking at.
    private var activeSessionUUID: String?
    private var activeTabId: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationDelegate.onActivate = { [weak self] id, term, sess, tmux, bundle, tty in
            focusTerminal(terminalType: term, itermSession: sess, tmuxWindowID: tmux, bundle: bundle, tty: tty)
            if let id = id { self?.store.markRead(id: id) }
        }
        NSUserNotificationCenter.default.delegate = notificationDelegate

        inboxVC = InboxViewController(store: store)
        inboxVC.onSelect = { [weak self] id in self?.focusAndRead(id) }
        inboxVC.onDismiss = { [weak self] id in self?.store.remove(id: id) }
        inboxVC.onClearAll = { [weak self] in self?.store.clearAll() }
        inboxVC.onSettings = { [weak self] view in self?.showSettingsMenu(from: view) }
        inboxVC.onDecision = { [weak self] id, d in self?.writeDecision(id, d) }

        store.onChange = { [weak self] in
            guard let self = self else { return }
            self.updateBadge()
            if self.window?.isVisible == true { self.inboxVC.refresh() }
        }

        // Restore the inbox from disk before anything can mutate it.
        store.load()
        syncRemoteApprovalsFlag()

        setupMainMenu()
        setupStatusItem()
        setupWindow()
        // Don't show the window here. A manual launch makes the app active, which triggers
        // applicationDidBecomeActive → showWindow. A Launch-at-Login start never becomes
        // active, so it stays in the background (Dock icon + badge) until the user clicks it.

        // Watch which iTerm2 session/tab is active, and auto-mark the matching pending
        // notification as read when the user switches to that tab (no click needed). Also
        // remember the active session/tab so a banner can be silenced for the focused tab.
        focusMonitor.onActiveSession = { [weak self] sid in
            self?.activeSessionUUID = extractSessionUUID(sid)
            self?.store.markReadByActiveSession(sid)
        }
        focusMonitor.onActiveTab = { [weak self] tab in
            self?.activeTabId = tab
            self?.store.markReadByActiveTab(tab)
        }
        focusMonitor.onHealthChange = { [weak self] ok in
            self?.inboxVC.iterm2Connected = ok
            self?.refreshInboxIfVisible()
        }
        focusMonitor.start()
        startEscalationTimer()
    }

    // MARK: Menu bar status item

    /// Bell in the system menu bar showing the unread count. Always visible (unlike the Dock
    /// badge, which hides with the Dock or in full-screen). Clicking opens a small menu.
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if let img = loadMenuBarIcon() {
                img.isTemplate = true
                btn.image = img
            } else if #available(macOS 11.0, *) {
                let img = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Claude Notifier")
                img?.isTemplate = true
                btn.image = img
            }
            btn.imagePosition = .imageLeading
            btn.font = .systemFont(ofSize: 11, weight: .medium)
        }
        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        updateBadge()
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar_icon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    @objc func openFromStatusItem(_ sender: Any?) { showWindow() }

    // MARK: Window

    func setupWindow() {
        let size = NSSize(width: 380, height: 480)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Claude Notifier"
        window.isReleasedWhenClosed = false   // closing hides the window; the app keeps running
        window.contentViewController = inboxVC
        window.setContentSize(size)
        // Lock the width (rows wrap to a fixed width); allow vertical resize.
        window.contentMinSize = NSSize(width: 380, height: 220)
        window.contentMaxSize = NSSize(width: 380, height: 100_000)
        window.setFrameAutosaveName("ClaudeNotifierMain")
        if window.frame.origin == .zero { window.center() }
        applyWindowLevel()
    }

    /// Float above other apps' windows when "Always on Top" is enabled.
    func applyWindowLevel() {
        window.level = UserDefaults.standard.bool(forKey: defaultsKeyAlwaysOnTop) ? .floating : .normal
    }

    func showWindow() {
        hasAutoShownWindow = true
        inboxVC.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inboxVC.focusList()
    }

    // Show the window the first time the app becomes active (i.e. a manual launch or the
    // first Dock click). Later activations don't re-show it, so closing the window sticks.
    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasAutoShownWindow { showWindow() }
    }

    // Keep running after the window is closed — this is a background notifier.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Flush the inbox to disk synchronously on quit (Cmd+Q, ://quit, SIGTERM all route here),
    // so the last few notifications survive even if a debounced save was still pending.
    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    // Reopen the window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func updateBadge() {
        let c = store.unreadCount
        NSApp.dockTile.badgeLabel = c > 0 ? "\(c)" : nil
        statusItem?.button?.title = c > 0 ? " \(c)" : ""
    }

    func focusAndRead(_ id: String) {
        if let item = store.items.first(where: { $0.id == id }) {
            focusTerminal(terminalType: item.terminal, itermSession: item.rawSession,
                          tmuxWindowID: item.tmux, bundle: item.bundle, tty: item.tty)
        }
        store.markRead(id: id)
    }

    // MARK: Menus

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (shows the app name automatically as its title)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Claude Notifier",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Claude Notifier",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Claude Notifier",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Notifications menu (rebuilt on open via NSMenuDelegate)
        let notifItem = NSMenuItem()
        mainMenu.addItem(notifItem)
        notificationsMenu = NSMenu(title: "Notifications")
        notificationsMenu.delegate = self
        notifItem.submenu = notificationsMenu
        populateNotifications(notificationsMenu)

        // Settings menu (rebuilt on open via NSMenuDelegate)
        let setItem = NSMenuItem()
        mainMenu.addItem(setItem)
        settingsMenu = NSMenu(title: "Settings")
        settingsMenu.delegate = self
        setItem.submenu = settingsMenu
        populateSettings(settingsMenu)

        // Window menu
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    /// Build the settings menu shown by the in-window gear button.
    func showSettingsMenu(from view: NSView) {
        let menu = NSMenu()
        populateNotifications(menu)
        menu.addItem(.separator())
        populateSettings(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func populateNotifications(_ menu: NSMenu) {
        let clearItem = NSMenuItem(title: "Clear All", action: #selector(clearAllNotifications(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = !store.items.isEmpty
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let testItem = NSMenuItem(title: "Test Notification", action: nil, keyEquivalent: "")
        let testMenu = NSMenu()
        for label in ["Running", "Waiting", "Review", "Done", "Failed", "Message"] {
            let item = NSMenuItem(title: label, action: #selector(testNotification(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = label.lowercased()
            testMenu.addItem(item)
        }
        testItem.submenu = testMenu
        menu.addItem(testItem)
    }

    private func populateSettings(_ menu: NSMenu) {
        let soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        let currentSound = UserDefaults.standard.string(forKey: defaultsKeySound) ?? "Ping"
        for sound in availableSounds {
            let label = sound.isEmpty ? "None" : sound
            let item = NSMenuItem(title: label, action: #selector(selectSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sound
            if sound == currentSound { item.state = .on }
            soundMenu.addItem(item)
        }
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        let perProjectItem = NSMenuItem(title: "Per-Project Sound", action: #selector(togglePerProjectSound(_:)), keyEquivalent: "")
        perProjectItem.target = self
        perProjectItem.state = UserDefaults.standard.bool(forKey: defaultsKeyPerProjectSound) ? .on : .off
        menu.addItem(perProjectItem)

        let perStatusItem = NSMenuItem(title: "Per-Status Sound", action: #selector(togglePerStatusSound(_:)), keyEquivalent: "")
        perStatusItem.target = self
        perStatusItem.state = UserDefaults.standard.bool(forKey: defaultsKeyPerStatusSound) ? .on : .off
        menu.addItem(perStatusItem)

        menu.addItem(NSMenuItem.separator())

        // Banner mode: Off / Auto-dismiss (transient) / Keep in Notification Center.
        let bannerItem = NSMenuItem(title: "Banner", action: nil, keyEquivalent: "")
        let bannerMenu = NSMenu()
        let mode = currentBannerMode()
        let bannerOptions: [(String, String)] = [
            ("off", "Off"),
            ("transient", "Auto-dismiss (don't keep in Notification Center)"),
            ("persist", "Keep in Notification Center"),
        ]
        for (value, label) in bannerOptions {
            let item = NSMenuItem(title: label, action: #selector(setBannerMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            if value == mode { item.state = .on }
            bannerMenu.addItem(item)
        }
        bannerItem.submenu = bannerMenu
        menu.addItem(bannerItem)

        // Do Not Disturb: manual pause presets + a fixed quiet-hours window.
        let dndItem = NSMenuItem(title: "Do Not Disturb", action: nil, keyEquivalent: "")
        let dndMenu = NSMenu()
        let paused = UserDefaults.standard.double(forKey: defaultsKeyPauseUntil) > Date().timeIntervalSince1970
        let pausePresets: [(String, Int)] = [
            ("Pause for 30 minutes", 30),
            ("Pause for 1 hour", 60),
            ("Pause for 4 hours", 240),
        ]
        for (label, mins) in pausePresets {
            let item = NSMenuItem(title: label, action: #selector(pauseFor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mins
            dndMenu.addItem(item)
        }
        let untilMorning = NSMenuItem(title: "Pause until 8 AM", action: #selector(pauseUntilMorning(_:)), keyEquivalent: "")
        untilMorning.target = self
        dndMenu.addItem(untilMorning)
        if paused {
            dndMenu.addItem(.separator())
            let resume = NSMenuItem(title: "Resume Now", action: #selector(resumeNotifications(_:)), keyEquivalent: "")
            resume.target = self
            dndMenu.addItem(resume)
        }
        dndMenu.addItem(.separator())
        let quiet = NSMenuItem(title: "Quiet Hours (10 PM – 8 AM)", action: #selector(toggleQuietHours(_:)), keyEquivalent: "")
        quiet.target = self
        quiet.state = UserDefaults.standard.bool(forKey: defaultsKeyQuietEnabled) ? .on : .off
        dndMenu.addItem(quiet)
        dndItem.submenu = dndMenu
        menu.addItem(dndItem)

        // One-time re-alert for unread high-importance items left untouched.
        let escItem = NSMenuItem(title: "Re-alert Unread", action: nil, keyEquivalent: "")
        let escMenu = NSMenu()
        let curEsc = UserDefaults.standard.integer(forKey: defaultsKeyEscalateMinutes)
        let escOptions: [(String, Int)] = [("Off", 0), ("After 2 minutes", 2), ("After 5 minutes", 5), ("After 10 minutes", 10)]
        for (label, mins) in escOptions {
            let item = NSMenuItem(title: label, action: #selector(setEscalateMinutes(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mins
            if mins == curEsc { item.state = .on }
            escMenu.addItem(item)
        }
        escItem.submenu = escMenu
        menu.addItem(escItem)

        let compactItem = NSMenuItem(title: "Compact Rows", action: #selector(toggleCompactRows(_:)), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = UserDefaults.standard.bool(forKey: defaultsKeyCompactRows) ? .on : .off
        menu.addItem(compactItem)

        let alwaysOnTopItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        alwaysOnTopItem.target = self
        alwaysOnTopItem.state = UserDefaults.standard.bool(forKey: defaultsKeyAlwaysOnTop) ? .on : .off
        menu.addItem(alwaysOnTopItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        let webhookSet = !(UserDefaults.standard.string(forKey: defaultsKeyWebhookURL) ?? "").isEmpty
        let webhookItem = NSMenuItem(title: "Webhook…", action: #selector(setWebhook(_:)), keyEquivalent: "")
        webhookItem.target = self
        webhookItem.state = webhookSet ? .on : .off
        menu.addItem(webhookItem)

        let remoteItem = NSMenuItem(title: "Remote Approvals (Bash)", action: #selector(toggleRemoteApprovals(_:)), keyEquivalent: "")
        remoteItem.target = self
        remoteItem.state = UserDefaults.standard.bool(forKey: defaultsKeyRemoteApprovals) ? .on : .off
        remoteItem.toolTip = "When on, Bash permission prompts can be approved/denied from this inbox (requires the approval hook)."
        menu.addItem(remoteItem)

        menu.addItem(NSMenuItem.separator())

        let installItem = NSMenuItem(title: "Install Claude Code Hooks…", action: #selector(installHooksClicked(_:)), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)
    }

    // Refresh the menu-bar Settings / Notifications menus right before they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === settingsMenu {
            menu.removeAllItems()
            populateSettings(menu)
        } else if menu === notificationsMenu {
            menu.removeAllItems()
            populateNotifications(menu)
        } else if menu === statusMenu {
            menu.removeAllItems()
            let open = menu.addItem(withTitle: "Open Claude Notifier",
                                    action: #selector(openFromStatusItem(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(.separator())
            populateNotifications(menu)
            menu.addItem(.separator())
            populateSettings(menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Claude Notifier",
                         action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        }
    }

    // MARK: Menu actions

    @objc func selectSound(_ sender: NSMenuItem) {
        guard let sound = sender.representedObject as? String else { return }
        if !sound.isEmpty { NSSound(named: NSSound.Name(sound))?.play() }
        UserDefaults.standard.set(sound, forKey: defaultsKeySound)
    }

    @objc func togglePerProjectSound(_ sender: NSMenuItem) {
        let newState = !UserDefaults.standard.bool(forKey: defaultsKeyPerProjectSound)
        UserDefaults.standard.set(newState, forKey: defaultsKeyPerProjectSound)
    }

    @objc func togglePerStatusSound(_ sender: NSMenuItem) {
        let newState = !UserDefaults.standard.bool(forKey: defaultsKeyPerStatusSound)
        UserDefaults.standard.set(newState, forKey: defaultsKeyPerStatusSound)
    }

    @objc func setBannerMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: defaultsKeyBannerMode)
    }

    @objc func pauseFor(_ sender: NSMenuItem) {
        guard let mins = sender.representedObject as? Int else { return }
        let until = Date().addingTimeInterval(Double(mins) * 60)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: defaultsKeyPauseUntil)
        refreshInboxIfVisible()
    }

    @objc func pauseUntilMorning(_ sender: NSMenuItem) {
        let cal = Calendar.current
        let now = Date()
        var target = cal.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        UserDefaults.standard.set(target.timeIntervalSince1970, forKey: defaultsKeyPauseUntil)
        refreshInboxIfVisible()
    }

    @objc func resumeNotifications(_ sender: NSMenuItem) {
        UserDefaults.standard.removeObject(forKey: defaultsKeyPauseUntil)
        refreshInboxIfVisible()
    }

    @objc func toggleQuietHours(_ sender: NSMenuItem) {
        let newState = !UserDefaults.standard.bool(forKey: defaultsKeyQuietEnabled)
        UserDefaults.standard.set(newState, forKey: defaultsKeyQuietEnabled)
        refreshInboxIfVisible()
    }

    @objc func setEscalateMinutes(_ sender: NSMenuItem) {
        guard let mins = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(mins, forKey: defaultsKeyEscalateMinutes)
    }

    @objc func toggleCompactRows(_ sender: NSMenuItem) {
        let v = !UserDefaults.standard.bool(forKey: defaultsKeyCompactRows)
        UserDefaults.standard.set(v, forKey: defaultsKeyCompactRows)
        refreshInboxIfVisible()
    }

    // MARK: Approve/Deny (I)

    @objc func toggleRemoteApprovals(_ sender: NSMenuItem) {
        let v = !UserDefaults.standard.bool(forKey: defaultsKeyRemoteApprovals)
        UserDefaults.standard.set(v, forKey: defaultsKeyRemoteApprovals)
        syncRemoteApprovalsFlag()
    }

    /// Mirror the Remote Approvals setting to the flag file the PreToolUse hook checks.
    private func syncRemoteApprovalsFlag() {
        let on = UserDefaults.standard.bool(forKey: defaultsKeyRemoteApprovals)
        if on {
            FileManager.default.createFile(atPath: remoteApprovalsFlagPath, contents: Data())
        } else {
            try? FileManager.default.removeItem(atPath: remoteApprovalsFlagPath)
        }
    }

    /// Write the user's Approve/Deny decision to the file the waiting hook polls, then mark read.
    private func writeDecision(_ id: String, _ decision: String) {
        if let item = store.items.first(where: { $0.id == id }), let req = item.decision {
            let url = URL(fileURLWithPath: "/tmp/claude-notifier-decision-\(req).json")
            if let data = try? JSONSerialization.data(withJSONObject: ["decision": decision]) {
                try? data.write(to: url, options: .atomic)
            }
        }
        store.markRead(id: id)
    }

    // MARK: Webhook forwarding (H)

    @objc func setWebhook(_ sender: NSMenuItem) {
        let a = NSAlert()
        a.messageText = "Forward notifications to a webhook"
        a.informativeText = "POST each notification as JSON to an HTTPS URL (ntfy, Pushover, Slack, …) so it reaches you when you're away from the Mac. Leave empty to disable."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: defaultsKeyWebhookURL) ?? ""
        field.placeholderString = "https://ntfy.sh/your-topic"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKeyWebhookURL)
        } else {
            UserDefaults.standard.set(v, forKey: defaultsKeyWebhookURL)
        }
    }

    /// Fire-and-forget POST of a notification to the user's webhook, if configured.
    private func forwardToWebhook(title: String, message: String, status: NotifStatus, source: String?) {
        guard let s = UserDefaults.standard.string(forKey: defaultsKeyWebhookURL), !s.isEmpty,
              let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["title": title, "message": message, "status": status.rawValue]
        if let src = source { payload["source"] = src }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: One-command hook setup (G)

    @objc func installHooksClicked(_ sender: NSMenuItem) { installClaudeHooks() }

    private func showAlert(_ style: NSAlert.Style, _ title: String, _ text: String) {
        let a = NSAlert(); a.alertStyle = style; a.messageText = title; a.informativeText = text
        a.runModal()
    }

    /// Merge the SessionStart + Notification hooks into ~/.claude/settings.json. Idempotent
    /// (re-running updates the claude-notifier entries instead of duplicating), backs up first,
    /// confirms with a preview, and refuses to touch a file that isn't a JSON object.
    private func installClaudeHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude", isDirectory: true)
        let url = dir.appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                showAlert(.warning, "Could not read settings.json",
                          "~/.claude/settings.json exists but is not a JSON object, so it was left untouched. Fix or remove it, then try again.")
                return
            }
            root = dict
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        func upsert(event: String, command: String, matcher: String?) {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            // Drop any prior claude-notifier groups so re-installing updates rather than duplicates.
            groups = groups.filter { group in
                let inner = (group["hooks"] as? [[String: Any]]) ?? []
                return !inner.contains { entry in
                    let cmd = (entry["command"] as? String) ?? ""
                    return cmd.contains("claude-notifier") || cmd.contains("claude-session-id")
                }
            }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if let m = matcher { group["matcher"] = m }
            groups.append(group)
            hooks[event] = groups
        }

        upsert(event: "SessionStart", command: sessionStartHookCommand, matcher: nil)
        upsert(event: "Notification", command: notificationHookCommand, matcher: "")
        // Approval hook is a no-op until Remote Approvals is enabled, so it's safe to install.
        upsert(event: "PreToolUse", command: approvalHookCommand, matcher: "Bash")
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys]) else {
            showAlert(.warning, "Failed to prepare settings", "Could not serialize the merged settings.")
            return
        }

        let preview = String(data: out, encoding: .utf8) ?? ""
        let confirm = NSAlert()
        confirm.messageText = "Install claude-notifier hooks?"
        confirm.informativeText = """
        This updates ~/.claude/settings.json (SessionStart + Notification). A timestamped backup \
        is saved first, and existing claude-notifier entries are replaced (not duplicated).

        Result preview:
        \(String(preview.prefix(1400)))
        """
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let bak = url.appendingPathExtension("bak-\(stamp)")
                try? FileManager.default.removeItem(at: bak)
                try FileManager.default.copyItem(at: url, to: bak)
            }
            try out.write(to: url, options: .atomic)
            showAlert(.informational, "Hooks installed",
                      "Updated ~/.claude/settings.json. Restart your Claude Code sessions for the hooks to take effect.")
        } catch {
            showAlert(.warning, "Failed to write settings.json", error.localizedDescription)
        }
    }

    private func refreshInboxIfVisible() {
        if window?.isVisible == true { inboxVC.refresh() }
    }

    @objc func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        let newState = !UserDefaults.standard.bool(forKey: defaultsKeyAlwaysOnTop)
        UserDefaults.standard.set(newState, forKey: defaultsKeyAlwaysOnTop)
        applyWindowLevel()
        // If turning it on, surface the window now so the effect is immediately visible.
        if newState { showWindow() }
    }

    @objc func testNotification(_ sender: NSMenuItem) {
        let param = (sender.representedObject as? String) ?? "message"
        let status = NotifStatus(param: param)
        store.add(NotificationItem(
            id: UUID().uuidString, sessionUUID: nil, tabId: nil,
            terminal: "unknown", terminalName: nil, rawSession: nil, tmux: nil, shortcut: nil,
            title: "claude-notifier", message: "Test notification (\(status.label))",
            status: status, date: Date(), read: false
        ))
    }

    @objc func clearAllNotifications(_ sender: NSMenuItem) {
        store.clearAll()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        setLaunchAtLogin(!isLaunchAtLoginEnabled())
    }

    @objc func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        // Remember the frontmost app so we can restore focus after delivering a banner.
        let previousApp = NSWorkspace.shared.frontmostApplication

        for url in urls {
            guard url.scheme == "claude-notifier" else { continue }
            switch url.host {
            case "notify":
                deliverNotification(from: url)
            case "quit":
                NSApp.terminate(nil)
            default:
                break
            }
        }

        // Restore focus to the previously active app
        previousApp?.activate(options: [.activateIgnoringOtherApps])
    }

    private func deliverNotification(from url: URL) {
        let params = parseQueryParams(from: url)
        // The hook always includes session=/tmux_window_id=, often empty; treat "" as absent.
        let twID = params["tmux_window_id"].flatMap { $0.isEmpty ? nil : $0 }
        let sess = params["session"].flatMap { $0.isEmpty ? nil : $0 }

        // One notification per tab: key on tmux window id, else session, else unique.
        let id = twID ?? sess ?? UUID().uuidString

        let projectName = params["title"] ?? "Claude Code"
        let messageText = params["message"] ?? ""
        let terminal = params["terminal"] ?? "unknown"
        let status = NotifStatus(param: params["status"])

        let terminalName = terminalDisplayNames[terminal]
        let bundle = terminalBundleIDs[terminal]
        let tty = params["tty"].flatMap { $0.isEmpty ? nil : $0 }
        var shortcut: String?
        var tabId: String?
        if terminal == "iterm2", let twID = twID {
            let info = iterm2LookupTab(tmuxWindowID: twID)
            shortcut = info.shortcut
            tabId = info.tabId
        }

        let soundName = resolvedSound(project: projectName, status: status, explicit: params["sound"])

        // If the user is already looking at the originating iTerm2 tab/session, land the
        // notification silently as read history (no banner, no sound, no badge bump).
        var focused = false
        if terminal == "iterm2" {
            if twID != nil, let tb = tabId, tb == activeTabId {
                focused = true
            } else if twID == nil, let s = sess, let active = activeSessionUUID,
                      extractSessionUUID(s) == active {
                focused = true
            }
        }

        // Banner/sound are suppressed when focused or while muted (quiet hours / manual pause);
        // the inbox still collects the item either way.
        if !focused && !isQuietNow() {
            presentBanner(id: id,
                          title: bannerTitle(project: projectName, terminalName: terminalName, shortcut: shortcut),
                          message: messageText, sound: soundName,
                          terminal: terminal, session: sess, tmux: twID, bundle: bundle, tty: tty)
            forwardToWebhook(title: projectName, message: messageText, status: status,
                             source: params["source"].flatMap { $0.isEmpty ? nil : $0 })
        }

        // Inbox (always)
        store.add(NotificationItem(
            id: id,
            sessionUUID: twID == nil ? sess.map(extractSessionUUID) : nil,
            tabId: tabId,
            terminal: terminal,
            terminalName: terminalName,
            rawSession: sess,
            tmux: twID,
            shortcut: shortcut,
            title: projectName,
            message: messageText,
            status: status,
            date: Date(),
            read: false,
            source: params["source"].flatMap { $0.isEmpty ? nil : $0 },
            bundle: bundle,
            tool: params["tool"].flatMap { $0.isEmpty ? nil : $0 },
            tty: tty,
            decision: params["decision"].flatMap { $0.isEmpty ? nil : $0 }
        ), forceRead: focused)
        // Visual arrival cue is the Dock badge (updated via store.onChange → updateBadge);
        // no Dock bounce, which the user found too noisy.
    }

    /// Build and deliver the native banner, honoring the banner mode. In "transient" mode the
    /// banner shows briefly then is removed from Notification Center, so the in-app inbox is the
    /// single place notifications accumulate. In "off" mode only the sound plays.
    private func presentBanner(id: String, title: String, message: String, sound: String,
                               terminal: String, session: String?, tmux: String?, bundle: String?,
                               tty: String? = nil) {
        let mode = currentBannerMode()
        if mode == "off" {
            if !sound.isEmpty { NSSound(named: NSSound.Name(sound))?.play() }
            return
        }

        let notification = NSUserNotification()
        notification.identifier = id
        notification.title = title
        notification.informativeText = message
        if !sound.isEmpty { notification.soundName = sound }
        var userInfo: [String: Any] = ["terminalType": terminal]
        if let session = session { userInfo["itermSession"] = session }
        if let tmux = tmux { userInfo["tmuxWindowID"] = tmux }
        if let bundle = bundle { userInfo["bundle"] = bundle }
        if let tty = tty { userInfo["tty"] = tty }
        notification.userInfo = userInfo

        let center = NSUserNotificationCenter.default
        // Remove an existing banner with the same ID first so the sound replays.
        for delivered in center.deliveredNotifications where delivered.identifier == id {
            center.removeDeliveredNotification(delivered)
        }
        center.deliver(notification)

        if mode == "transient" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                for d in NSUserNotificationCenter.default.deliveredNotifications where d.identifier == id {
                    NSUserNotificationCenter.default.removeDeliveredNotification(d)
                }
            }
        }
    }

    /// Sound priority: URL param > per-status (if enabled) > per-project (if enabled) > user default.
    private func resolvedSound(project: String, status: NotifStatus, explicit: String?) -> String {
        if let e = explicit, !e.isEmpty { return e }
        if UserDefaults.standard.bool(forKey: defaultsKeyPerStatusSound) { return status.defaultSound }
        if UserDefaults.standard.bool(forKey: defaultsKeyPerProjectSound) {
            return projectSounds[stableSoundIndex(project, projectSounds.count)]
        }
        return UserDefaults.standard.string(forKey: defaultsKeySound) ?? ""
    }

    /// Banner title like "⌘3 project — iTerm".
    private func bannerTitle(project: String, terminalName: String?, shortcut: String?) -> String {
        guard let tn = terminalName else { return project }
        return shortcut != nil ? "\(shortcut!) \(project) — \(tn)" : "\(project) — \(tn)"
    }

    // MARK: One-time escalation

    /// Periodically re-alert (once) for an unread, high-importance item that has sat untouched
    /// past the user-set threshold. A single nudge, never a recurring nag.
    func startEscalationTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkEscalations() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkEscalations() {
        let mins = UserDefaults.standard.integer(forKey: defaultsKeyEscalateMinutes)
        guard mins > 0, !isQuietNow() else { return }
        let threshold = Double(mins) * 60
        let now = Date()
        for item in store.items {
            guard !item.read, !item.escalated,
                  [.review, .failed, .waiting].contains(item.status),
                  now.timeIntervalSince(item.date) >= threshold else { continue }
            presentBanner(id: item.id,
                          title: bannerTitle(project: item.title, terminalName: item.terminalName, shortcut: item.shortcut),
                          message: item.message,
                          sound: resolvedSound(project: item.title, status: item.status, explicit: nil),
                          terminal: item.terminal, session: item.rawSession, tmux: item.tmux,
                          bundle: item.bundle, tty: item.tty)
            store.markEscalated(id: item.id)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let appDelegate = AppDelegate()
app.delegate = appDelegate

// Handle SIGTERM for graceful shutdown
signal(SIGTERM) { _ in
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

app.run()
