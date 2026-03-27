import AppKit

// MARK: - CLI Argument Parsing

struct Config {
    var title: String?
    var message: String?
    var sound: String?
    var itermSession: String?
    var terminalType: String = "unknown"
}

func parseArguments() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--title":
            i += 1
            if i < args.count { config.title = args[i] }
        case "--message":
            i += 1
            if i < args.count { config.message = args[i] }
        case "--sound":
            i += 1
            if i < args.count { config.sound = args[i] }
        case "--iterm-session":
            i += 1
            if i < args.count { config.itermSession = args[i] }
        default:
            break
        }
        i += 1
    }

    // Read message from stdin if not provided via --message
    if config.message == nil {
        if isatty(fileno(stdin)) == 0 {
            config.message = readLine(strippingNewline: false)
            if let msg = config.message {
                config.message = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            config.message = ""
        }
    }

    // Default title: "Claude Code — {basename of $PWD}"
    if config.title == nil {
        let env = ProcessInfo.processInfo.environment
        if let pwd = env["PWD"] {
            let basename = (pwd as NSString).lastPathComponent
            config.title = "Claude Code — \(basename)"
        } else {
            config.title = "Claude Code"
        }
    }

    // Detect terminal type from environment variables
    let env = ProcessInfo.processInfo.environment
    if env["ITERM_SESSION_ID"] != nil {
        config.terminalType = "iterm2"
        // Session ID must be provided via --iterm-session (from `it2 session get-var id`)
    } else if env["TERM_PROGRAM"] == "vscode" {
        config.terminalType = "vscode"
    } else if env["TERM_PROGRAM"] == "Apple_Terminal" {
        config.terminalType = "terminal"
    } else {
        config.terminalType = "unknown"
    }

    return config
}

// MARK: - Notification Delegate (NSUserNotificationCenter)

class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    private var delivered = false

    // Show notification only on first delivery
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        if !delivered {
            delivered = true
            return true
        }
        return false
    }

    // Called when notification is tapped
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        // Remove the notification to prevent re-display
        NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        let userInfo = notification.userInfo ?? [:]
        let terminalType = userInfo["terminalType"] as? String ?? "unknown"
        let itermSession = userInfo["itermSession"] as? String

        switch terminalType {
        case "iterm2":
            if let itermURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
                NSWorkspace.shared.open(itermURL)
            }
            if let session = itermSession, !session.isEmpty {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/Users/sato/.local/bin/it2")
                process.arguments = ["session", "focus", session]
                try? process.run()
                process.waitUntilExit()
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

        NSApp.terminate(nil)
    }
}

// MARK: - Main

let config = parseArguments()

// Set up as agent app (no dock icon, no menu bar)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = NotificationDelegate()
let center = NSUserNotificationCenter.default
center.delegate = delegate

// Remove existing notification with the same identifier to allow sound replay
let notificationId = "claude-notifier-\(config.title ?? "default")"
for delivered in center.deliveredNotifications {
    if delivered.identifier == notificationId {
        center.removeDeliveredNotification(delivered)
    }
}

// Create and deliver notification
let notification = NSUserNotification()
notification.identifier = notificationId
notification.title = config.title ?? "Claude Code"
notification.informativeText = config.message ?? ""

if let soundName = config.sound {
    notification.soundName = soundName
}


// Store terminal type and session ID in userInfo for the tap handler
var userInfo: [String: Any] = ["terminalType": config.terminalType]
if let session = config.itermSession {
    userInfo["itermSession"] = session
}
notification.userInfo = userInfo

center.deliver(notification)

// Wait for user to interact with notification, then exit
// Timeout after 30 seconds if no interaction
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    NSApp.terminate(nil)
}
app.run()
