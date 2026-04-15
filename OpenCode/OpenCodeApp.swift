import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct OpenCodeApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// Set from a notification tap; ContentView reads it to switch sessions.
    @State private var pendingSessionID: String?

    init() {
        #if os(iOS)
        BackgroundRefreshService.shared.registerTask()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pendingSessionID: $pendingSessionID)
                #if os(iOS)
                .task {
                    NotificationService.shared.onOpenSession = { sid in
                        pendingSessionID = sid
                    }
                    if AppSettings.shared.notificationsEnabled {
                        _ = await NotificationService.shared.requestAuthorizationIfNeeded()
                    }
                }
                #endif
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                BackgroundRefreshService.shared.scheduleNext()
            default:
                break
            }
        }
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // NotificationService installs itself as UNUserNotificationCenter delegate
        // on first access; touch the singleton here so taps on cold-launch
        // notifications reach us.
        _ = NotificationService.shared
        return true
    }
}
#endif
