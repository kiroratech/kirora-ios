#if canImport(UIKit) && !os(watchOS)
import Network
@preconcurrency import ObjectiveC
import UIKit
@preconcurrency import UserNotifications

// MARK: - Lifecycle

/// The app's lifecycle from UIKit's notifications, the network from `NWPathMonitor`.
final class UIKitLifecycle: AppLifecycleSource, @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    private var keepAliveTimer: Timer?
    private var monitor: NWPathMonitor?
    private var launched = false
    private var handler: (@Sendable (LifecycleEvent) -> Void)?

    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) {
        // Handled off the main thread, in order: handling may wait for the files' first read,
        // and UIKit calls from the main thread, at launch too. Going to the background, with
        // time from iOS to finish.
        let deliver: @Sendable (LifecycleEvent) -> Void = { event in
            guard event == .background else { return lifecycleQueue.async { handler(event) } }
            runWithBackgroundTime("Kirora background") {
                await withCheckedContinuation { done in
                    lifecycleQueue.async {
                        handler(event)
                        done.resume()
                    }
                }
            }
        }
        onMain { [self] in
            self.handler = deliver
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.enteredForeground() })
            observers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.enteredBackground() })
            // A scene-based app is still in the background while it finishes launching: its
            // first trip to the foreground is the launch.
            if UIApplication.shared.applicationState != .background { enteredForeground() }
            let monitor = NWPathMonitor()
            let wasOffline = Locked(false)
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                let cameBack = wasOffline.withLock { wasOffline -> Bool in
                    defer { wasOffline = !online }
                    return online && wasOffline
                }
                // `handler` is only touched on the main thread.
                if cameBack { onMain { [weak self] in self?.handler?(.online) } }
            }
            monitor.start(queue: DispatchQueue(label: "io.kirora.sdk.network", qos: .utility))
            self.monitor = monitor
        }
    }

    func stop() {
        onMain { [self] in
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
            monitor?.cancel()
            monitor = nil
            handler = nil
        }
    }

    func runInBackground(_ name: String, _ work: @escaping @Sendable () async -> Void) {
        runWithBackgroundTime(name, work)
    }

    private func enteredForeground() {
        handler?(launched ? .foreground : .launched)
        launched = true
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: sessionKeepAlive, repeats: true) { [weak self] _ in
            self?.handler?(.keepAlive)
        }
    }

    private func enteredBackground() {
        // Never seen in the foreground: launched in the background (e.g. for a silent push).
        guard launched else { return }
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        handler?(.background)
    }
}

/// Reads the screen for event context, once, on the main thread: its portrait size in
/// points, which rotation doesn't change, and its scale.
func readDeviceScreen() {
    onMain {
        guard deviceScreen.current == nil else { return }
        let screen = UIScreen.main
        let bounds = screen.fixedCoordinateSpace.bounds
        deviceScreen.withLock {
            $0 = DeviceInfo.Screen(width: Int(bounds.width), height: Int(bounds.height), density: Double(screen.scale))
        }
    }
}

/// Where every client's lifecycle events are handled: one at a time, in order.
private let lifecycleQueue = DispatchQueue(label: "io.kirora.sdk.lifecycle", qos: .utility)

/// Runs `work`, asking iOS for time to finish it if the app goes to the background.
func runWithBackgroundTime(_ name: String, _ work: @escaping @Sendable () async -> Void) {
    onMain {
        let application = UIApplication.shared
        let task = Locked<UIBackgroundTaskIdentifier?>(nil)
        // Ended once, whichever comes first: the work finishing, or iOS's time running out.
        let end: @Sendable () -> Void = {
            onMain {
                if let identifier = task.take() { application.endBackgroundTask(identifier) }
            }
        }
        task.withLock { $0 = application.beginBackgroundTask(withName: name, expirationHandler: end) }
        Task {
            await work()
            end()
        }
    }
}

/// Runs `work` on the main thread: at once if already there, as installing the push
/// integration must happen before `didFinishLaunching` returns to hear a launching tap.
func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

// MARK: - Push platform

struct UIKitPushPlatform: PushPlatform {
    var isSupported: Bool { true }

    func authorization() async -> PushAuthorization {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined: continuation.resume(returning: .notDetermined)
                case .denied: continuation.resume(returning: .denied)
                // Authorized, provisional and ephemeral all deliver.
                default: continuation.resume(returning: .authorized)
                }
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }

    func registerForRemoteNotifications() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onMain {
                UIApplication.shared.registerForRemoteNotifications()
                continuation.resume()
            }
        }
    }

    func firebaseToken() async -> String? {
        await FirebaseMessagingBridge.token()
    }
}

/// Reads Firebase's registration token from FirebaseMessaging when the app includes it,
/// through the Objective-C runtime, so the SDK never links Firebase itself.
enum FirebaseMessagingBridge {
    /// Posted by FirebaseMessaging when its token changes
    /// (`FIRMessagingRegistrationTokenRefreshedNotification`).
    static let tokenRefreshed = Notification.Name("com.firebase.iid.notif.fcm-token")

    private static var messaging: NSObject? {
        let selector = NSSelectorFromString("messaging")
        guard let messagingClass = NSClassFromString("FIRMessaging") as? NSObject.Type,
              messagingClass.responds(to: selector) else { return nil }
        return messagingClass.perform(selector)?.takeUnretainedValue() as? NSObject
    }


    /// The token, waiting up to 10 seconds for Firebase to make one.
    @MainActor
    static func token() async -> String? {
        guard let messaging else { return nil }
        if let token = messaging.value(forKey: "FCMToken") as? String, !token.isEmpty { return token }
        let selector = NSSelectorFromString("tokenWithCompletion:")
        guard messaging.responds(to: selector) else { return nil }
        // FirebaseMessaging is thread-safe; it's only handed over to be called back.
        let shared = UncheckedSendable(messaging)
        return try? await withTimeout(seconds: 10) {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let completion: @convention(block) (NSString?, NSError?) -> Void = { token, _ in
                    continuation.resume(returning: token as String?)
                }
                _ = shared.value.perform(selector, with: completion)
            }
        }
    }
}

// MARK: - Automatic integration

/// Wires push into the app without app code, as Firebase and Customer.io do: the APNs token
/// from the app delegate, and taps from `UNUserNotificationCenter`'s delegate, which the SDK
/// wraps so the app's own delegate still gets every call.
///
/// An app turns it off with `KiroraAppDelegateProxyEnabled` set to `NO` in its Info.plist,
/// then calls ``Kirora``'s `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// and `userNotificationCenter(_:didReceive:withCompletionHandler:)` itself.
enum PushIntegration {
    static var automatic: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "KiroraAppDelegateProxyEnabled") as? Bool) ?? true
    }

    private static let installed = Locked(false)

    fileprivate static let firebaseObserved = Locked(false)

    static func install(log: Log) {
        observeFirebaseTokens()
        guard automatic else {
            log.debug("KiroraAppDelegateProxyEnabled is NO: the app forwards push callbacks itself")
            return
        }
        guard installed.claimOnce() else { return }
        onMain {
            NotificationCenterProxy.shared.install()
            if let delegate = UIApplication.shared.delegate {
                AppDelegateProxy.install(on: delegate)
            } else {
                // Created before the app delegate (e.g. in a SwiftUI App's init): wait for it.
                let observer = Locked<NSObjectProtocol?>(nil)
                observer.withLock { stored in
                    stored = NotificationCenter.default.addObserver(
                        forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main
                    ) { _ in
                        if let token = observer.take() { NotificationCenter.default.removeObserver(token) }
                        onMain {
                            if let delegate = UIApplication.shared.delegate { AppDelegateProxy.install(on: delegate) }
                        }
                    }
                }
            }
        }
    }
}

extension PushIntegration {
    /// Installs the integration at launch, before any client exists, for a wrapper whose
    /// client is created late, from JavaScript or Dart. iOS hands a tap that launched the app
    /// to the notification center's delegate as the launch finishes, and only then.
    ///
    /// Safe from `+load` (before `UIApplicationMain`), from `didFinishLaunching`, or later: it
    /// installs now if the app exists, else when it does, at the latest as launching finishes,
    /// as React Native Firebase's messaging module does. Once, however often it's called.
    static func installAtLaunch(log: Log) {
        if Thread.isMainThread, applicationExists() {
            install(log: log)
            return
        }
        let observer = Locked<NSObjectProtocol?>(nil)
        observer.withLock { stored in
            stored = NotificationCenter.default.addObserver(
                forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { _ in
                if let token = observer.take() { NotificationCenter.default.removeObserver(token) }
                install(log: log)
            }
        }
        // The main queue first runs inside `UIApplicationMain`, once the app exists: often
        // before the app's `didFinishLaunching`, never after the notification above.
        DispatchQueue.main.async {
            guard applicationExists() else { return }
            if let token = observer.take() { NotificationCenter.default.removeObserver(token) }
            install(log: log)
        }
    }

    /// Whether `UIApplication.shared` exists yet. Read through the runtime: before
    /// `UIApplicationMain`, Swift's non-optional `shared` would crash.
    private static func applicationExists() -> Bool {
        (UIApplication.self as AnyObject).value(forKey: "sharedApplication") != nil
    }

    /// A new Firebase token registers the device again, for push apps that send through
    /// Firebase. Needs no swizzling, so it's on whether or not the automatic integration is.
    static func observeFirebaseTokens() {
        guard firebaseObserved.claimOnce() else { return }
        NotificationCenter.default.addObserver(
            forName: FirebaseMessagingBridge.tokenRefreshed, object: nil, queue: nil
        ) { _ in
            PushTokens.shared.firebaseTokenChanged()
        }
    }
}

/// Adds the SDK to the app delegate's APNs token callbacks. The app's own implementation
/// runs first, unchanged; a SwiftUI app's adaptor is reached through its forwarding target.
enum AppDelegateProxy {
    private typealias Implementation = @convention(c) (AnyObject, Selector, UIApplication, AnyObject) -> Void
    private typealias Block = @convention(block) (AnyObject, UIApplication, AnyObject) -> Void

    private static let swizzled = Locked(Set<ObjectIdentifier>())

    static func install(on delegate: UIApplicationDelegate) {
        guard let delegateClass = object_getClass(delegate) else { return }
        // Once per class, including a superclass done already, or the SDK would hear twice.
        var ancestor: AnyClass? = delegateClass
        while let current = ancestor {
            if swizzled.withLock({ $0.contains(ObjectIdentifier(current)) }) { return }
            ancestor = class_getSuperclass(current)
        }
        swizzled.withLock { _ = $0.insert(ObjectIdentifier(delegateClass)) }
        add(
            to: delegateClass,
            #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        ) { argument in
            if let token = argument as? Data { PushTokens.shared.received(token) }
        }
        add(
            to: delegateClass,
            #selector(UIApplicationDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:))
        ) { _ in
            PushTokens.shared.failed()
        }
    }

    private static func add(to delegateClass: AnyClass, _ selector: Selector, handler: @escaping (AnyObject) -> Void) {
        let original = class_getInstanceMethod(delegateClass, selector)
            .map { unsafeBitCast(method_getImplementation($0), to: Implementation.self) }
        let block: Block = { receiver, application, argument in
            if let original {
                original(receiver, selector, application, argument)
            } else if let target = (receiver as? NSObject)?.forwardingTarget(for: selector) as? NSObject,
                      target.responds(to: selector),
                      let targetClass = object_getClass(target) {
                let forwarded = unsafeBitCast(class_getMethodImplementation(targetClass, selector), to: Implementation.self)
                forwarded(target, selector, application, argument)
            }
            handler(argument)
        }
        class_replaceMethod(delegateClass, selector, imp_implementationWithBlock(block), "v@:@@")
    }
}

/// How long the app's notification delegate has to call a Kirora tap's completion handler
/// before the SDK calls it, as for the app's other callbacks.
let appDelegateAnswerTimeout: Double = wrapperCallbackTimeout

/// The notification center's delegate: the SDK's, passing every call on to the app's own.
/// When the app (or another SDK) sets a delegate later, that one becomes the one passed to,
/// and this stays installed.
// Its state is only touched on the main thread, where iOS calls a notification center's
// delegate and the SDK installs it.
final class NotificationCenterProxy: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationCenterProxy()

    /// The app's delegate. Weak, as the notification center's own is.
    weak var appDelegate: UNUserNotificationCenterDelegate?

    private typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias SetterBlock = @convention(block) (AnyObject, AnyObject?) -> Void

    func install() {
        let center = UNUserNotificationCenter.current()
        let selector = #selector(setter: UNUserNotificationCenter.delegate)
        guard let centerClass = object_getClass(center),
              let method = class_getInstanceMethod(centerClass, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: SetterBlock = { receiver, newDelegate in
            let proxy = NotificationCenterProxy.shared
            if newDelegate !== proxy { proxy.appDelegate = newDelegate as? UNUserNotificationCenterDelegate }
            original(receiver, selector, proxy)
        }
        if let existing = center.delegate, existing !== self { appDelegate = existing }
        class_replaceMethod(centerClass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        center.delegate = self
    }

    /// The SDK decides whether a Kirora push shows in the foreground, before the app's delegate
    /// is asked (an app decides through the wrapper's foreground handler). A delegate can't be
    /// trusted to: in Flutter, `FlutterAppDelegate` asks every plugin, and the first to answer,
    /// often with `[]` for a push it didn't make (`firebase_messaging` does), decides for all.
    /// Anyone else's push is the app's alone.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        if Kirora.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler) { return }
        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        guard let appDelegate, appDelegate.responds(to: selector) else { return completionHandler([]) }
        appDelegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
    }

    /// Kirora's taps are handled by the SDK first, then passed on. A delegate that leaves a
    /// Kirora tap unanswered has it answered for it after 1.5 seconds, as iOS expects.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let isKiroras = Kirora.handleTap(response)
        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        guard let appDelegate, appDelegate.responds(to: selector) else { return completionHandler() }
        guard isKiroras else {
            appDelegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            return
        }
        askWithFallback(
            timeout: appDelegateAnswerTimeout,
            answer: { (_: Void) in completionHandler() },
            ask: { answer in
                appDelegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: { answer(()) })
            },
            fallback: { answer in answer(()) }
        )
    }

    @available(iOS 12.0, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        appDelegate?.userNotificationCenter?(center, openSettingsFor: notification)
    }

    override func responds(to selector: Selector!) -> Bool {
        // Only claim "open settings" if the app handles it: iOS shows a button for it then.
        if selector == #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:)) {
            return appDelegate?.responds(to: selector) ?? false
        }
        return super.responds(to: selector)
    }
}

/// Opens a push's link: first the app's `handleDeepLink`, if it opens the link itself. A web
/// link then goes to the app as a universal link: to the scene delegate in a scene-based
/// app (SwiftUI's included), or the app delegate. Anything else, including an app link
/// (`myapp://…`), goes to `UIApplication.open`.
@MainActor
func openPushLink(_ url: URL, handleDeepLink: (@MainActor @Sendable (URL) -> Bool)?) {
    if handleDeepLink?(url) == true { return }
    let application = UIApplication.shared
    // A web link the app delegate says it handled (a universal link of its own) stays in
    // the app. A scene delegate is never handed one: its `scene(_:continue:)` can't say
    // whether it did, so an external link it ignores would open nothing. A scene-based app
    // claims its own universal links in `handleDeepLink`; anything unclaimed opens with iOS,
    // in the browser or the app that owns it.
    if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        if application.delegate?.application?(application, continue: activity, restorationHandler: { _ in }) == true {
            return
        }
    }
    application.open(url, options: [:], completionHandler: nil)
}
#endif
