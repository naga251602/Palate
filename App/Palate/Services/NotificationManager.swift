import UserNotifications
import Foundation

class NotificationManager {
    static let shared = NotificationManager()

    // Call this after successful login to ensure the device token
    // (which was captured before login) is uploaded to Supabase.
    func uploadPendingTokenIfNeeded() {
        guard SupabaseClient.shared.isAuthenticated,
              let token = UserDefaults.standard.string(forKey: "sb_pending_push_token")
        else { return }
        Task {
            do {
                try await SupabaseClient.shared.registerPushToken(token)
                print("[APNs] Uploaded pending push token after login")
            } catch {
                print("[APNs] Failed to upload pending push token: \(error)")
            }
        }
    }

    // Schedule a local notification N hours before a reservation
    func scheduleReservationReminder(restaurantName: String, date: Date, hoursBeforehand: Double = 3) {
        let content = UNMutableNotificationContent()
        content.title = "Reservation Tonight 🍽️"
        content.body = "Your table at \(restaurantName) is in \(Int(hoursBeforehand)) hours. Bon appétit!"
        content.sound = .default

        let fireDate = date.addingTimeInterval(-hoursBeforehand * 3600)
        guard fireDate > Date() else { return }

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let id = "reservation-\(restaurantName)-\(date.timeIntervalSince1970)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { err in
            if let err { print("Notification error: \(err)") }
        }
    }

    func cancelReservationReminder(restaurantName: String, date: Date) {
        let id = "reservation-\(restaurantName)-\(date.timeIntervalSince1970)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
