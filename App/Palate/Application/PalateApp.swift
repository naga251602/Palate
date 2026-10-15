import SwiftUI
import EventKit
import UserNotifications

@main
struct PalateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        LocationManager.shared.requestPermission()
        // Calendar permission
        let store = EKEventStore()
        store.requestFullAccessToEvents { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(.dark)
        }
    }
}

// MARK: - AppDelegate
// Handles the full APNs lifecycle:
//   1. Request user permission for alerts/sound/badge
//   2. Only call registerForRemoteNotifications() if permission granted (not before)
//   3. Store the device token locally and upload to Supabase once authenticated
//   4. Re-upload stored token after sign-in so it's never missed
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Ask for permission. On iOS, calling registerForRemoteNotifications() before
        // the user grants .alert permission means the OS will never show banners — the
        // device gets a "silent" APNs token only. We chain them here so registration
        // only happens when the user has actually said yes.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                print("[APNs] Permission error: \(error.localizedDescription)")
            }
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            } else {
                print("[APNs] User denied push notification permission")
            }
        }
        return true
    }

    // Called by iOS with the device token once registration succeeds.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[APNs] Got device token: \(token.prefix(16))...")

        // Always persist locally so we can upload after login
        UserDefaults.standard.set(token, forKey: "sb_pending_push_token")

        // Upload immediately if already logged in
        if SupabaseClient.shared.isAuthenticated {
            Task { try? await SupabaseClient.shared.registerPushToken(token) }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] Registration failed: \(error.localizedDescription)")
    }

    // Show banner + sound + badge even when the app is foregrounded
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Task { await AppState.shared.refreshNotifications() }
        return [.banner, .sound, .badge]
    }

    // User tapped a push notification — refresh data and open the panel
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await AppState.shared.refreshNotifications()
        await MainActor.run {
            NotificationCenter.default.post(name: .openNotificationsPanel, object: nil)
        }
    }
}
