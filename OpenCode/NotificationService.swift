import Foundation
#if os(iOS)
import UIKit
import UserNotifications

/// Local-notification helpers. No remote push — everything is posted by the
/// background refresh task when it finds new assistant messages.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    /// Action the user wants triggered when they tap a notification.
    var onOpenSession: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let sessionIDKey = "sessionID"
    private let messageIDKey = "messageID"

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }

    func postNewMessage(sessionTitle: String, preview: String, sessionID: String, messageID: String) {
        let content = UNMutableNotificationContent()
        content.title = sessionTitle
        content.body = preview
        content.sound = .default
        content.userInfo = [sessionIDKey: sessionID, messageIDKey: messageID]
        content.threadIdentifier = sessionID

        // Identifier is derived from messageID so re-delivering the same message
        // just replaces the existing notification instead of stacking.
        let request = UNNotificationRequest(
            identifier: "msg.\(messageID)",
            content: content,
            trigger: nil
        )
        center.add(request) { err in
            if let err = err { print("[Notification] add error: \(err)") }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    // Show banner/sound even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sid = response.notification.request.content.userInfo["sessionID"] as? String
        await MainActor.run { [weak self] in
            guard let self, let sid else { return }
            self.onOpenSession?(sid)
        }
    }
}
#endif
