import Foundation
import UserNotifications

/// Best-effort passive macOS notification when the hook hard-denies a command (approval-ux.spec.md:
/// "so a 2am block isn't silent"). Informational only - no action buttons (the spec found banner
/// actions unreliable in the VSCode extension, and a hard deny is intentionally not one-click
/// allowable). Posted by the running app, not the hook, so it surfaces like any local notification.
final class DenyNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false

    /// Ask once for permission and register as delegate (so banners show even if the app is active).
    func requestAuth() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Show the banner even when the menu-bar app counts as foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
