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

/// Build a keyboard shortcut string like "⌘3" from tab lookup result.
func shortcutString(from result: TabLookupResult) -> String? {
    let tabNum = result.tabIndex + 1
    guard tabNum <= 9 else { return nil }
    return "⌘\(tabNum)"
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

func focusTerminal(terminalType: String, itermSession: String?, tmuxWindowID: String?) {
    switch terminalType {
    case "iterm2":
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
    case "vscode":
        activateApp(bundleID: "com.microsoft.VSCode")
    case "terminal":
        activateApp(bundleID: "com.apple.Terminal")
    default:
        break
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
        defer { Darwin.close(fd) }
        guard websocketHandshake(fd) else { return }

        reqId += 1; _ = websocketSendBinary(fd, buildSubscribeFocusMessage(id: reqId))
        reqId += 1; _ = websocketSendBinary(fd, buildFocusRequestMessage(id: reqId))
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

let defaultsKeyBannerEnabled = "bannerEnabled"
let defaultsKeyAlwaysOnTop = "alwaysOnTop"

/// Semantic task state carried by the `status` URL param. Drives the row's status dot.
enum NotifStatus {
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
struct NotificationItem {
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
}

/// In-memory inbox. Newest item first. `onChange` fires after any mutation.
/// All callers run on the main thread (URL open + FocusMonitor callbacks are
/// dispatched to main), so no locking is needed.
final class NotificationStore {
    private(set) var items: [NotificationItem] = []
    var onChange: (() -> Void)?
    private let maxItems = 50

    var unreadCount: Int { items.reduce(0) { $0 + ($1.read ? 0 : 1) } }

    /// Add a notification, or refresh the existing one for the same tab (dedup by id).
    func add(_ item: NotificationItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            // Same tab notified again: replace the whole entry (so freshly resolved
            // routing metadata like tabId/shortcut wins), mark unread, float to top,
            // and bump the repeat count so stacked notifications are visible as ×N.
            var updated = item
            // Reset the stack count once the row was read/acknowledged; otherwise keep
            // counting the current unread streak.
            updated.count = items[i].read ? 1 : items[i].count + 1
            updated.read = false
            items.remove(at: i)
            items.insert(updated, at: 0)
        } else {
            items.insert(item, at: 0)
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
        }
        onChange?()
    }

    func markRead(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
        onChange?()
    }

    /// The user switched to an iTerm session: auto-read its pending notification.
    func markReadByActiveSession(_ sessionID: String) {
        let uuid = extractSessionUUID(sessionID)
        var changed = false
        for i in items.indices where !items[i].read && items[i].sessionUUID == uuid {
            items[i].read = true; changed = true
        }
        if changed { onChange?() }
    }

    /// The user switched to an iTerm tab: auto-read pending notifications bound to it.
    func markReadByActiveTab(_ tabId: String) {
        var changed = false
        for i in items.indices where !items[i].read && items[i].tabId == tabId {
            items[i].read = true; changed = true
        }
        if changed { onChange?() }
    }

    func remove(id: String) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { onChange?() }
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        onChange?()
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

    private let dismissButton = NSButton()
    private var hovered = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    init(item: NotificationItem, width: CGFloat) {
        self.id = item.id
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
        if let sc = item.shortcut { metaParts.append(sc) }
        if let tn = item.terminalName { metaParts.append(tn) }
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
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingTail
        message.cell?.truncatesLastVisibleLine = true
        message.preferredMaxLayoutWidth = max(120, width - 64)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.isHidden = item.message.isEmpty

        let textCol = NSStackView(views: item.message.isEmpty ? [titleRow] : [titleRow, message])
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
        layer?.backgroundColor = hovered
            ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
    }

    // Route clicks: × → the dismiss button, everything else → this row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        let pInSelf = convert(point, from: sv)
        guard bounds.contains(pInSelf) else { return nil }
        let pInBtn = dismissButton.convert(pInSelf, from: self)
        if dismissButton.bounds.contains(pInBtn) { return dismissButton }
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

/// The inbox content view: a header (unread count, clear-all, settings gear) over a
/// scrollable list of notification rows, or an empty-state label. Hosted in the main
/// window (set as the window's contentViewController).
final class InboxViewController: NSViewController {
    private let store: NotificationStore
    var onSelect: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onClearAll: (() -> Void)?
    var onSettings: ((NSView) -> Void)?

    private let contentWidth: CGFloat = 380
    private let headerHeight: CGFloat = 38

    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let docView = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "No notifications")

    init(store: NotificationStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 480))

        // --- Header ---
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

        let header = NSStackView(views: [countLabel, spacer, clearButton, gear])
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

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
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

    @objc private func clearClicked() { onClearAll?() }
    @objc private func settingsClicked(_ sender: NSButton) { onSettings?(sender) }

    /// Rebuild the row list from the store.
    func refresh() {
        loadViewIfNeeded()

        // Preserve scroll position across the full rebuild (e.g. an auto-read while the
        // user is scrolled down should not yank the list back to the top).
        let savedScroll = scrollView.contentView.bounds.origin

        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let items = store.items
        let unread = store.unreadCount
        countLabel.stringValue = unread > 0 ? "\(unread) pending" : (items.isEmpty ? "" : "all read")
        clearButton.isHidden = items.isEmpty
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty

        for (idx, item) in items.enumerated() {
            let row = NotificationRowView(item: item, width: contentWidth)
            row.onSelect = { [weak self] id in self?.onSelect?(id) }
            row.onDismiss = { [weak self] id in self?.onDismiss?(id) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if idx < items.count - 1 {
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
}

// MARK: - Notification Delegate

class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    /// Called when the user clicks a native banner: (inbox id, terminal, session, tmux).
    var onActivate: ((String?, String, String?, String?) -> Void)?

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
            userInfo["tmuxWindowID"] as? String
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
    private var hasAutoShownWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            defaultsKeyBannerEnabled: true
        ])

        notificationDelegate.onActivate = { [weak self] id, term, sess, tmux in
            focusTerminal(terminalType: term, itermSession: sess, tmuxWindowID: tmux)
            if let id = id { self?.store.markRead(id: id) }
        }
        NSUserNotificationCenter.default.delegate = notificationDelegate

        inboxVC = InboxViewController(store: store)
        inboxVC.onSelect = { [weak self] id in self?.focusAndRead(id) }
        inboxVC.onDismiss = { [weak self] id in self?.store.remove(id: id) }
        inboxVC.onClearAll = { [weak self] in self?.store.clearAll() }
        inboxVC.onSettings = { [weak self] view in self?.showSettingsMenu(from: view) }

        store.onChange = { [weak self] in
            guard let self = self else { return }
            self.updateBadge()
            if self.window?.isVisible == true { self.inboxVC.refresh() }
        }

        setupMainMenu()
        setupWindow()
        // Don't show the window here. A manual launch makes the app active, which triggers
        // applicationDidBecomeActive → showWindow. A Launch-at-Login start never becomes
        // active, so it stays in the background (Dock icon + badge) until the user clicks it.

        // Watch which iTerm2 session/tab is active, and auto-mark the matching pending
        // notification as read when the user switches to that tab (no click needed).
        focusMonitor.onActiveSession = { [weak self] sid in self?.store.markReadByActiveSession(sid) }
        focusMonitor.onActiveTab = { [weak self] tab in self?.store.markReadByActiveTab(tab) }
        focusMonitor.start()
    }

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

    // Reopen the window when the user clicks the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func updateBadge() {
        let c = store.unreadCount
        NSApp.dockTile.badgeLabel = c > 0 ? "\(c)" : nil
    }

    func focusAndRead(_ id: String) {
        if let item = store.items.first(where: { $0.id == id }) {
            focusTerminal(terminalType: item.terminal, itermSession: item.rawSession, tmuxWindowID: item.tmux)
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

        menu.addItem(NSMenuItem.separator())

        let bannerItem = NSMenuItem(title: "Notification Banner", action: #selector(toggleBanner(_:)), keyEquivalent: "")
        bannerItem.target = self
        bannerItem.state = UserDefaults.standard.bool(forKey: defaultsKeyBannerEnabled) ? .on : .off
        menu.addItem(bannerItem)

        let alwaysOnTopItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        alwaysOnTopItem.target = self
        alwaysOnTopItem.state = UserDefaults.standard.bool(forKey: defaultsKeyAlwaysOnTop) ? .on : .off
        menu.addItem(alwaysOnTopItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)
    }

    // Refresh the menu-bar Settings / Notifications menus right before they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === settingsMenu {
            menu.removeAllItems()
            populateSettings(menu)
        } else if menu === notificationsMenu {
            menu.removeAllItems()
            populateNotifications(menu)
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

    @objc func toggleBanner(_ sender: NSMenuItem) {
        let newState = !UserDefaults.standard.bool(forKey: defaultsKeyBannerEnabled)
        UserDefaults.standard.set(newState, forKey: defaultsKeyBannerEnabled)
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
        var terminalName: String?
        var shortcut: String?
        var tabId: String?

        switch terminal {
        case "iterm2":
            terminalName = "iTerm"
            if let twID = twID {
                let info = iterm2LookupTab(tmuxWindowID: twID)
                shortcut = info.shortcut
                tabId = info.tabId
            }
        case "vscode":
            terminalName = "VS Code"
        case "terminal":
            terminalName = "Terminal"
        default:
            break
        }

        // Sound priority: URL param > per-project auto-assign (if enabled) > user default
        let soundName: String
        if let explicit = params["sound"], !explicit.isEmpty {
            soundName = explicit
        } else if UserDefaults.standard.bool(forKey: defaultsKeyPerProjectSound) {
            soundName = projectSounds[stableSoundIndex(projectName, projectSounds.count)]
        } else {
            soundName = UserDefaults.standard.string(forKey: defaultsKeySound) ?? ""
        }

        // Native banner (optional)
        if UserDefaults.standard.bool(forKey: defaultsKeyBannerEnabled) {
            let notification = NSUserNotification()
            notification.identifier = id
            if let tn = terminalName {
                if let sc = shortcut {
                    notification.title = "\(sc) \(projectName) — \(tn)"
                } else {
                    notification.title = "\(projectName) — \(tn)"
                }
            } else {
                notification.title = projectName
            }
            notification.informativeText = messageText
            if !soundName.isEmpty { notification.soundName = soundName }
            var userInfo: [String: Any] = ["terminalType": terminal]
            if let sess = sess { userInfo["itermSession"] = sess }
            if let twID = twID { userInfo["tmuxWindowID"] = twID }
            notification.userInfo = userInfo

            let center = NSUserNotificationCenter.default
            // Remove existing notification with same ID so the sound replays.
            for delivered in center.deliveredNotifications where delivered.identifier == id {
                center.removeDeliveredNotification(delivered)
            }
            center.deliver(notification)
        } else if !soundName.isEmpty {
            // No banner: still play the sound so the user hears the notification.
            NSSound(named: NSSound.Name(soundName))?.play()
        }

        // Inbox (always)
        let status = NotifStatus(param: params["status"])
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
            read: false
        ))
        // Visual arrival cue is the Dock badge (updated via store.onChange → updateBadge);
        // no Dock bounce, which the user found too noisy.
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
