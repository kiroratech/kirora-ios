#if canImport(UIKit) && !os(watchOS)
import UIKit
import UserNotifications

/// Push callbacks, for apps that set `KiroraAppDelegateProxyEnabled` to `NO` in their
/// Info.plist and forward them by hand. Otherwise the SDK hears them itself, and calling
/// these too is harmless: each tap is reported once.
extension Kirora {
    /// Call from your app delegate's method of the same name.
    public static func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushTokens.shared.received(deviceToken)
    }

    /// Call from your app delegate's method of the same name.
    public static func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushTokens.shared.failed()
    }

    /// Call from your `UNUserNotificationCenterDelegate`'s method of the same name. For a
    /// Kirora push it reports the tap, opens the push's link and calls `completionHandler`,
    /// and returns true. For anyone else's push it does nothing and returns false: handle it
    /// and call `completionHandler` yourself.
    @discardableResult
    public static func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) -> Bool {
        guard handleTap(response) else { return false }
        completionHandler()
        return true
    }

    /// Call from your `UNUserNotificationCenterDelegate`'s method of the same name to show
    /// Kirora pushes while the app is open. Returns false, without calling
    /// `completionHandler`, for anyone else's push.
    @discardableResult
    public static func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) -> Bool {
        guard let options = foregroundPresentation(for: notification.request.content.userInfo) else { return false }
        completionHandler(options)
        return true
    }

    /// Kirora pushes show while the app is open, as they would outside it; anyone else's
    /// are left as iOS does by default, unshown.
    /// Nil for anyone else's push.
    static func foregroundPresentation(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions? {
        guard KiroraPushPayload(userInfo: userInfo) != nil else { return nil }
        if #available(iOS 14.0, *) { return [.banner, .list, .sound, .badge] }
        // `.alert`, by value: deprecated from iOS 14, which takes the branch above.
        return [UNNotificationPresentationOptions(rawValue: 1 << 2), .sound, .badge]
    }

    /// Reports a tap on a Kirora push and opens its link, once per tap.
    /// False for anyone else's push. Kirora's are handled once, however often they're passed.
    @discardableResult
    static func handleTap(_ response: UNNotificationResponse) -> Bool {
        let request = response.notification.request
        guard let payload = KiroraPushPayload(userInfo: request.content.userInfo) else { return false }
        guard firstTimeHandling("\(request.identifier)|\(response.actionIdentifier)") else { return true }
        let action: PushTapHandler.Action
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case UNNotificationDismissActionIdentifier: action = .dismiss
        default: action = .other
        }
        let handleDeepLink = deepLinkHandler.current
        let handler = PushTapHandler(openURL: { url in
            await MainActor.run { openPushLink(url, handleDeepLink: handleDeepLink) }
        })
        // The app may be suspended right after the tap is handed back to iOS.
        runWithBackgroundTime("Kirora push tap") { await handler.handle(payload, action: action) }
        return true
    }
}
#endif
