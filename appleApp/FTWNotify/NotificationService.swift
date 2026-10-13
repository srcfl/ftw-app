import Foundation
import FTWShared
import os
import UserNotifications

/// Writes every FTW notification on the phone.
///
/// FTW Cloud forwards the box's signed event and nothing of its own. This
/// checks the signature with the box key the app left in the App Group,
/// writes the words from the kind in the person's language, and picks the
/// buttons from a verified kind alone. Anything that does not check out
/// shows the generic line with no buttons. It links FTWShared only: no
/// session, no secret key, nothing on the main actor.
final class NotificationService: UNNotificationServiceExtension {
    private let log = Logger(subsystem: "energy.ftw.app", category: "push")
    private var deliver: ((UNNotificationContent) -> Void)?
    private var userInfo: [AnyHashable: Any] = [:]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        deliver = contentHandler
        userInfo = request.content.userInfo
        let nowMs = Date.now.timeIntervalSince1970 * 1000
        let keys = CloudKeys.shared()
        let alert = PushAlert.read(userInfo: userInfo, boxKey: { keys?.boxKey(home: $0) }, offset: { keys?.offset(home: $0) }, nowMs: Int64(nowMs))
        log.info("push: \(alert.verdict.rawValue, privacy: .public) \(alert.kind, privacy: .public)")
        if let seen = PushSeen.shared(), !seen.accept(alert, nowMs: nowMs) {
            log.info("push: seen before, seq \(alert.seq, privacy: .public)")
            finish(content(.repeated(alert, language: .preferred())))
            return
        }
        finish(content(PushNotice(alert, home: keys?.read(home: alert.home), language: .preferred())))
    }

    /// Out of time: the generic line, which claims nothing.
    override func serviceExtensionTimeWillExpire() {
        finish(content(.generic(.preferred())))
    }

    private func finish(_ content: UNNotificationContent) {
        guard let deliver else { return }
        self.deliver = nil
        deliver(content)
    }

    /// New content, so nothing the service put in "aps" survives: not a
    /// title, not a category, not a priority. The payload stays in
    /// userInfo, because the app checks it again before a button acts.
    private func content(_ notice: PushNotice) -> UNNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = notice.title
        c.body = notice.body
        c.sound = notice.sound ? .default : nil
        c.categoryIdentifier = notice.category
        c.threadIdentifier = notice.thread
        c.interruptionLevel = notice.level
        var info = userInfo
        info[PushNotice.userInfoKey] = notice.verified
        c.userInfo = info
        return c
    }
}
