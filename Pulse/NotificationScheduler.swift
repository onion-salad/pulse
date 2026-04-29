import Foundation
import UserNotifications

struct NotificationScheduler {
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func schedule(moments: [CaptureMoment]) async throws {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        for (index, moment) in moments.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Pulse #\(index + 1)"
            content.body = "今の2秒を撮ろう"
            content.sound = .default
            content.userInfo = ["momentID": moment.id.uuidString]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: moment.scheduledAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: moment.id.uuidString, content: content, trigger: trigger)
            try await center.add(request)
        }
    }
}

