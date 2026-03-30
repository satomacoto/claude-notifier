import AppKit
import ServiceManagement

// MARK: - Constants

let availableSounds = ["", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                       "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

let defaultsKeySound = "defaultSound"

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

/// Find the iTerm2 tab_id for a tmux window by querying ListSessions.
func iterm2FindTabForTmuxWindow(_ tmuxWindowID: String, fd: Int32) -> String? {
    let msg = buildListSessionsMessage()
    guard websocketSendBinary(fd, msg) else { return nil }
    guard let payload = readWebSocketPayload(fd) else { return nil }

    // ServerOriginatedMessage → list_sessions_response (field 106)
    guard let listResp = extractMessages(payload, fieldNumber: 106).first else { return nil }

    // ListSessionsResponse → windows (field 1) → tabs (field 1)
    for window in extractMessages(listResp, fieldNumber: 1) {
        for tab in extractMessages(window, fieldNumber: 1) {
            let tmuxIds = extractStrings(tab, fieldNumber: 4)
            if tmuxIds.contains(tmuxWindowID) {
                return extractStrings(tab, fieldNumber: 2).first
            }
        }
    }
    return nil
}

/// Focus an iTerm2 tmux window by looking up the tab via ListSessions, then activating it.
func iterm2FocusTmuxWindow(_ tmuxWindowID: String) -> Bool {
    // Strip "@" prefix if present (tmux uses @N, iTerm2 API uses just N)
    let winID = tmuxWindowID.hasPrefix("@") ? String(tmuxWindowID.dropFirst()) : tmuxWindowID

    let path = iterm2SocketPath()
    guard FileManager.default.fileExists(atPath: path),
          let fd = connectUDS(path) else { return false }
    defer { Darwin.close(fd) }

    guard websocketHandshake(fd) else { return false }

    guard let tabID = iterm2FindTabForTmuxWindow(winID, fd: fd) else { return false }

    let msg = buildActivateTabMessage(tabID: tabID)
    guard websocketSendBinary(fd, msg) else { return false }
    _ = readWebSocketPayload(fd)
    return true
}

// MARK: - Terminal Focus

/// Bring an app to the foreground by bundle identifier.
func activateApp(bundleID: String) {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}

func focusTerminal(terminalType: String, itermSession: String?, tmuxWindowID: String?) {
    switch terminalType {
    case "iterm2":
        // 1) tmux integration → ListSessions to find matching tab, then Activate
        if let twID = tmuxWindowID, !twID.isEmpty, iterm2FocusTmuxWindow(twID) {
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

// MARK: - Notification Delegate

class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
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
        let terminalType = userInfo["terminalType"] as? String ?? "unknown"
        let itermSession = userInfo["itermSession"] as? String
        let tmuxWindowID = userInfo["tmuxWindowID"] as? String
        focusTerminal(terminalType: terminalType, itermSession: itermSession, tmuxWindowID: tmuxWindowID)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let notificationDelegate = NotificationDelegate()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUserNotificationCenter.default.delegate = notificationDelegate
        setupStatusItem()
    }

    // MARK: Status Bar Menu

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let icon = NSImage(named: "menubar_icon") {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.title = ">✦"
            }
        }
        statusItem.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Sound submenu
        let soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        let currentSound = UserDefaults.standard.string(forKey: defaultsKeySound) ?? "Ping"

        for sound in availableSounds {
            let label = sound.isEmpty ? "None" : sound
            let item = NSMenuItem(title: label, action: #selector(selectSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sound
            if sound == currentSound {
                item.state = .on
            }
            soundMenu.addItem(item)
        }
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc func selectSound(_ sender: NSMenuItem) {
        guard let sound = sender.representedObject as? String else { return }

        // Preview the sound
        if !sound.isEmpty {
            NSSound(named: NSSound.Name(sound))?.play()
        }

        UserDefaults.standard.set(sound, forKey: defaultsKeySound)
        statusItem.menu = buildMenu()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !isLaunchAtLoginEnabled()
        setLaunchAtLogin(newState)
        statusItem.menu = buildMenu()
    }

    @objc func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        // Remember the frontmost app so we can restore focus after delivering notification
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

        let notification = NSUserNotification()
        // Use session ID as identifier so same-tab notifications replace each other
        notification.identifier = params["session"] ?? UUID().uuidString
        notification.title = params["title"] ?? "Claude Code"
        notification.informativeText = params["message"] ?? ""

        // URL param overrides default; fall back to user preference
        let soundName = params["sound"] ?? UserDefaults.standard.string(forKey: defaultsKeySound) ?? ""
        if !soundName.isEmpty {
            notification.soundName = soundName
        }

        var userInfo: [String: Any] = [
            "terminalType": params["terminal"] ?? "unknown"
        ]
        if let session = params["session"], !session.isEmpty {
            userInfo["itermSession"] = session
        }
        if let twID = params["tmux_window_id"], !twID.isEmpty {
            userInfo["tmuxWindowID"] = twID
        }
        notification.userInfo = userInfo

        // Remove existing notification with same ID so sound replays
        let center = NSUserNotificationCenter.default
        for delivered in center.deliveredNotifications {
            if delivered.identifier == notification.identifier {
                center.removeDeliveredNotification(delivered)
            }
        }
        center.deliver(notification)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let appDelegate = AppDelegate()
app.delegate = appDelegate

// Handle SIGTERM for graceful shutdown
signal(SIGTERM) { _ in
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

app.run()
