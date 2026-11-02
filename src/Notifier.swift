import AppKit
import UserNotifications

/// Native notifications, under the app's own name and icon, with "Try Again" and
/// "Troubleshoot…" buttons. Only used by the menu bar app; the command line logs instead.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Runs on the main queue when the person picks a recovery from a notification.
    var onRecovery: ((Recovery) -> Void)?

    private var center: UNUserNotificationCenter? {
        isAppMode && Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let retry = UNNotificationAction(identifier: "retry", title: "Try Again", options: [])
        let fix = UNNotificationAction(identifier: "fix", title: "Troubleshoot…", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "failure", actions: [retry, fix], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "problem", actions: [fix], intentIdentifiers: [], options: []),
        ])
    }

    /// Asked from the last step of the setup assistant, after explaining why.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            say("Notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \($0)" } ?? "")")
        }
    }

    func postFailure(_ error: UserError, jobTitle: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = error.title == UserError.printerNotFound.title ? "Label didn’t print: printer not found" : error.title
        content.body = error.message
        content.sound = .default
        content.categoryIdentifier = hasFailedJob ? "failure" : "problem"
        content.userInfo = ["recovery": error.recovery.rawValue]
        center.add(UNNotificationRequest(identifier: "failure", content: content, trigger: nil))
    }

    func postInfo(_ title: String, _ body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: "info", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let stored = Recovery(rawValue: response.notification.request.content.userInfo["recovery"] as? String ?? "") ?? .none
        let recovery: Recovery
        switch response.actionIdentifier {
        case "retry": recovery = .tryAgain
        case "fix": recovery = stored == .tryAgain || stored == .none ? .runSetup : stored
        default: recovery = stored
        }
        DispatchQueue.main.async { self.onRecovery?(recovery) }
        completionHandler()
    }
}

/// Spoken by VoiceOver, also when another app is in front.
func announce(_ text: String) {
    DispatchQueue.main.async {
        guard isAppMode, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
