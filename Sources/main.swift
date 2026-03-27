import AppKit

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

// MARK: - Terminal Focus

func focusTerminal(terminalType: String, itermSession: String?) {
    switch terminalType {
    case "iterm2":
        if let itermURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
            NSWorkspace.shared.open(itermURL)
        }
        if let session = itermSession, !session.isEmpty {
            // Resolve it2 from $PATH
            let env = ProcessInfo.processInfo.environment
            let path = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            var it2Path: String?
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/it2"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    it2Path = candidate
                    break
                }
            }
            if let it2 = it2Path {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: it2)
                process.arguments = ["session", "focus", session]
                try? process.run()
                process.waitUntilExit()
            }
        }
    case "vscode":
        if let vscodeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open(vscodeURL)
        }
    case "terminal":
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
    default:
        break
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
        focusTerminal(terminalType: terminalType, itermSession: itermSession)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUserNotificationCenter.default.delegate = notificationDelegate
    }

    func application(_ application: NSApplication, open urls: [URL]) {
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
    }

    private func deliverNotification(from url: URL) {
        let params = parseQueryParams(from: url)

        let notification = NSUserNotification()
        // Use session ID as identifier so same-tab notifications replace each other
        notification.identifier = params["session"] ?? UUID().uuidString
        notification.title = params["title"] ?? "Claude Code"
        notification.informativeText = params["message"] ?? ""

        if let soundName = params["sound"], !soundName.isEmpty {
            notification.soundName = soundName
        }

        var userInfo: [String: Any] = [
            "terminalType": params["terminal"] ?? "unknown"
        ]
        if let session = params["session"], !session.isEmpty {
            userInfo["itermSession"] = session
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
