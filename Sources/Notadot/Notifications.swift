import AppKit
import UserNotifications

final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    var openJob: ((String) -> Void)?
    private var requested = false
    func show(_ title: String, _ text: String, job: String) {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        func deliver() {
            let content = UNMutableNotificationContent(); content.title = title; content.body = text; content.sound = .default
            content.userInfo = ["job": job]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if !requested { requested = true; center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in if allowed { deliver() } } }
        else { center.getNotificationSettings { settings in if settings.authorizationStatus == .authorized { deliver() } } }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let job = response.notification.request.content.userInfo["job"] as? String { DispatchQueue.main.async { self.openJob?(job) } }
        completionHandler()
    }
}
