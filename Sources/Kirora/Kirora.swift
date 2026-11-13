import Foundation

/// The Kirora client. Create one for the whole app, as early as possible: in
/// `application(_:didFinishLaunchingWithOptions:)`, or your SwiftUI `App`'s `init`.
///
/// Nothing is sent until ``identify(_:)``: events tracked before that wait on the device and
/// go as the user who signs in. A failing Kirora never throws from ``track(_:properties:)``
/// and never breaks the app.
///
/// ```swift
/// let kirora = Kirora(options: KiroraOptions(
///     clientKey: "kirora_pk_…",
///     fetchUserToken: { try await MyServer.kiroraToken() },
///     push: .enabled
/// ))
/// try await kirora.identify()
/// kirora.track("Order Completed", properties: ["order_id": "1042", "total": 46.5])
/// ```
public final class Kirora: @unchecked Sendable {
    private let options: KiroraOptions
    private let log: Log
    private let identity: Identity
    private let api: ClientAPI
    private let store: KeyValueStore
    private let queue: EventQueue
    private let consent: TrackingConsent
    private let deviceId: DeviceId
    private let tracker: Tracker
    private let delivery: EventDelivery
    private let push: PushRegistrar
    private let appOpens: AppOpens
    private let lifecycle: AppLifecycleSource
    private let lifecycleEvents: LifecycleEvents
    private let releaseDeviceId: DeviceIdRelease
    private let now: @Sendable () -> Date
    private let logoutWait: Double
    private let destroyedFlag = Locked(false)
    private let stopObservingTokens: @Sendable () -> Void

    /// Starts the client. Never throws and never blocks the app's launch: a bad option is
    /// logged, and the client then sends nothing.
    public convenience init(options: KiroraOptions) {
        self.init(options: options, environment: .live(log: Log(level: options.logLevel)))
    }

    init(options: KiroraOptions, environment: KiroraEnvironment) {
        self.options = options
        let log = Log(level: options.logLevel)
        self.log = log
        now = environment.now
        logoutWait = environment.logoutWait
        if !options.clientKey.hasPrefix("kirora_pk_") {
            log.error("clientKey should be your client key, kirora_pk_…")
        }
        identity = Identity(fetchUserToken: options.fetchUserToken, tokenTimeout: environment.tokenTimeout)
        api = ClientAPI(
            clientKey: options.clientKey, apiUrl: options.apiUrl,
            identity: identity, transport: environment.transport
        )
        if let problem = api.urlProblem { log.error(problem) }
        store = environment.store
        queue = EventQueue(file: environment.eventsFile(api.namespace))
        consent = TrackingConsent(store: store, required: options.requireTrackingConsent)
        deviceId = DeviceId(store: store)
        let delivery = EventDelivery(
            api: api, identity: identity, queue: queue,
            consentAllowed: { [consent] in consent.allowed },
            log: log, timing: environment.timing, now: environment.now
        )
        self.delivery = delivery
        tracker = Tracker(
            identity: identity, queue: queue, consent: consent,
            sessions: Sessions(store: store, now: environment.now),
            deviceId: deviceId, deviceInfo: environment.deviceInfo,
            trackSessions: options.trackSessions, log: log, now: environment.now,
            onQueued: { waiting in Task { await delivery.onEventQueued(waiting: waiting) } }
        )
        let releaseDeviceId = DeviceIdRelease(consent: consent, deviceId: deviceId)
        push = PushRegistrar(
            api: api, identity: identity, store: store, options: options.push,
            deviceId: deviceId, deviceInfo: environment.deviceInfo,
            platform: environment.pushPlatform, tokens: environment.tokens,
            log: log, timing: environment.timing, now: environment.now,
            // Kept past a consent withdrawal only so the device could be detached.
            onDetached: { releaseDeviceId.ifUnneeded(registered: false) }
        )
        self.releaseDeviceId = releaseDeviceId
        appOpens = AppOpens(
            api: api, identity: identity, store: store, registrar: push, deviceId: deviceId,
            log: log, timing: environment.timing, now: environment.now
        )
        lifecycle = environment.lifecycle
        lifecycleEvents = LifecycleEvents(store: store, deviceInfo: environment.deviceInfo)

        // A new APNs or Firebase token while signed in registers again.
        let push = self.push
        let stopObserving: @Sendable () -> Void = { }
        stopObservingTokens = push.enabled ? environment.tokens.observe { push.registerInBackground() } : stopObserving
        // What's stored from before the user refused, e.g. before consent was required. Off
        // the app's thread, as it reads the disk; nothing is tracked meanwhile, as tracking
        // checks the same answer.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.tracker.forget(if: { self.consent.refused }) {
                self.releaseDeviceId.ifUnneeded(registered: self.push.registered)
            }
        }
        if push.enabled { environment.installPushIntegration(log) }
        deepLinkHandler.withLock { $0 = options.handleDeepLink }
        lifecycle.start { [weak self] event in self?.handle(event) }
    }

    deinit {
        // Released without destroy(): its timers, observers and retries go too.
        destroy()
    }

    /// Signs the user in and starts sending their queued events. Call it at every start
    /// while they're signed in. Without a token, it asks `fetchUserToken` for one. If called
    /// again before a token arrives, the latest call wins.
    ///
    /// Also registers the device for push if the user allowed notifications.
    ///
    /// - Throws: Only for the token: ``UserTokenError`` if `fetchUserToken` fails, or
    ///   ``KiroraApiError`` with status 401 if Kirora refuses a fresh one too. A push
    ///   registration that fails otherwise is logged.
    public func identify(_ userToken: String? = nil) async throws {
        guard !destroyed else { return }
        try await identity.signIn(token: userToken) { [weak self] in try await self?.onSignedIn() }
    }

    /// Call before your own sign-out. Tries to send queued events, detaches this device from
    /// the user's pushes, then forgets the user and anything still unsent. Safe to call twice.
    ///
    /// Never fails your sign-out, and waits 5 seconds at most to send and detach: if Kirora
    /// can't be reached, the SDK keeps trying to detach the device in the background, and
    /// the user is forgotten all the same.
    public func logout() async {
        guard !destroyed else { return }
        // One deadline for all of it, a sign-in still under way included.
        let deadline = Date().addingTimeInterval(logoutWait)
        let identity = self.identity
        // Otherwise that sign-in's push registration could land after the detachment.
        let signInSettled = (try? await withTimeout(seconds: logoutWait) { await identity.settled() }) != nil
        // Still waiting for its token: it never signs anyone in now, so it can't bring the
        // user back after this logout. Whoever is signed in is signed out as usual.
        if !signInSettled { identity.abandonPendingSignIn() }
        guard let user = identity.user else { return }
        // Past the deadline, the user is forgotten all the same, and a detachment still under
        // way carries on in the background, behind any registration it must follow.
        let delivery = self.delivery, push = self.push
        let sendAndDetach = Task {
            // Independent: the detachment waits only for registrations, not for events.
            async let sent: Void = delivery.flush()
            await push.detach(user)
            await sent
        }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { _ = try? await withTimeout(seconds: remaining) { await sendAndDetach.value } }
        // Anything left belongs to this user, so don't send it as the next one. Events from
        // before sign-in go too, unless the next user is already signed in to send them;
        // and if that's this user again, nothing of theirs goes.
        if identity.signOut(user) {
            queue.clear(owner: user.subject)
            appOpens.clear(owner: user.subject)
        } else if identity.user?.subject != user.subject {
            queue.clearOwned { owner, _ in owner == user.subject }
            appOpens.clear(owner: user.subject)
        }
    }

    /// Queues an event, with a copy of `properties` as they are now. Returns at once and
    /// never throws: an event Kirora refuses is logged, and the rest still go through.
    ///
    /// Properties must be JSON: strings, numbers, booleans, `nil`/`NSNull`, arrays and
    /// dictionaries of them. Dates are sent as ISO 8601 strings, URLs and UUIDs as strings;
    /// anything else is left out and logged.
    public func track(_ name: String, properties: [String: Any] = [:]) {
        guard !destroyed else { return }
        var dropped: [String] = []
        let converted = JSONValue.fromObject(properties, dropped: &dropped)
        if !dropped.isEmpty {
            log.error("\(name): left out properties JSON can't hold: \(dropped.sorted().joined(separator: ", "))")
        }
        tracker.track(name, properties: converted)
    }

    /// Tracks `Screen Viewed` with the screen's name, as your app calls it: `Checkout`.
    /// Screens are never tracked automatically.
    public func trackScreenView(_ name: String) {
        guard !destroyed else { return }
        tracker.track(screenViewedEvent, properties: ["name": .string(name)])
    }

    /// The user's answer, for ``KiroraOptions/requireTrackingConsent``. Remembered on the
    /// device. Withdrawing consent also forgets queued events, the visit, and the device id
    /// unless a push registration still needs it.
    public func setTrackingConsent(_ granted: Bool) {
        let newlyAllowed = consent.answer(granted)
        if !granted {
            tracker.forget()
            releaseDeviceId.ifUnneeded(registered: push.registered)
        }
        guard newlyAllowed, !destroyed else { return }
        // Catch up on the visit we skipped while waiting for consent, and send what waited.
        tracker.noteActivity()
        Task { await delivery.flush() }
    }

    /// Shows iOS's notification prompt, then registers the device if the user allows it.
    /// iOS shows the prompt once; after that this answers with the user's earlier choice.
    ///
    /// - Returns: ``PushPermission/unsupported`` when ``KiroraOptions/push`` is off.
    public func requestPushPermission() async -> PushPermission {
        await push.requestPermission()
    }

    /// Records the user's consent to marketing pushes, as your app asked them. The
    /// notification permission alone doesn't grant it.
    public func setPushConsent(_ granted: Bool) async throws {
        await identity.settled()
        guard !destroyed else { return }
        try await api.request("PUT", "/push-consent", body: JSONValue.object(["granted": .bool(granted)]))
    }

    /// Sends queued events now; rarely needed. Returning doesn't mean all were accepted:
    /// after a network or server failure they wait for a retry.
    public func flush() async {
        await delivery.flush()
        appOpens.send()
    }

    /// Stops this client's timers and observers at once, without sending or deleting
    /// anything: for tests, or replacing the client. A destroyed client tracks and sends
    /// nothing; events still waiting stay on the device for the next client.
    public func destroy() {
        guard destroyedFlag.claimOnce() else { return }
        // Forgetting the user stops work already under way for them at its next step.
        identity.end()
        lifecycle.stop()
        appOpens.destroy()
        push.stop()
        stopObservingTokens()
        let delivery = self.delivery
        Task { await delivery.destroy() }
        // Nothing to wait for: the next client reads the files on the same queues, after
        // this one's writes.
    }

    // MARK: - Internals

    private var destroyed: Bool { destroyedFlag.current }

    /// Once signed in: send what waits, and register this device for push.
    private func onSignedIn() async throws {
        let user = identity.user
        // Events left by earlier sign-ins with tokens naming no one: they'd otherwise wait for
        // good. Only once they're old, as another client may still be signed in to send them.
        let staleBefore = now().addingTimeInterval(-24 * 60 * 60)
        queue.clearOwned { owner, event in
            owner != user?.subject && isUnnamedSubject(owner)
                && (parseIsoTimestamp(event.occurredAt) ?? .distantPast) < staleBefore
        }
        let delivery = self.delivery
        Task { await delivery.flush() }
        do {
            try await push.register()
        } catch let error as KiroraApiError where error.status == 401 {
            throw error
        } catch let error as UserTokenError {
            throw error
        } catch {
            log.error("Push registration failed", error)
        }
        if let user { appOpens.onSignedIn(user) }
    }

    private func handle(_ event: LifecycleEvent) {
        guard !destroyed else { return }
        switch event {
        case .launched:
            tracker.noteActivity()
            if options.trackAppLifecycle { tracker.trackAll(lifecycleEvents.launch) }
            appOpens.appCameToForeground()
        case .foreground:
            tracker.noteActivity()
            if options.trackAppLifecycle {
                let (name, properties) = lifecycleEvents.opened(fromBackground: true)
                tracker.track(name, properties: properties)
            }
            appOpens.appCameToForeground()
            // Notices notifications turned off in Settings, and refreshes a day-old registration.
            push.registerInBackground()
        case .background:
            if options.trackAppLifecycle { tracker.track(applicationBackgroundedEvent, properties: [:]) }
            tracker.keepSessionAlive(writeNow: true)
            appOpens.appWentToBackground()
            // The last chance to send before iOS suspends the app.
            let delivery = self.delivery
            lifecycle.runInBackground("Kirora flush") {
                await delivery.flush()
                PersistentFile.waitForAllWrites()
            }
        case .keepAlive:
            tracker.keepSessionAlive()
            appOpens.touchVisit()
        case .online:
            Task { await self.flush() }
        }
    }

}

/// The rule for `device.id`: it goes once tracking consent is refused, unless a push
/// registration still needs it (it's also the installation id). Checked whenever either
/// changes: at a refusal, and when the device is detached.
struct DeviceIdRelease: Sendable {
    let consent: TrackingConsent
    let deviceId: DeviceId

    func ifUnneeded(registered: Bool) {
        if consent.refused, !registered { deviceId.remove() }
    }
}

/// What the client runs on: the device in the app, fakes in tests.
struct KiroraEnvironment {
    var transport: HTTPTransport
    var store: KeyValueStore
    var eventsFile: (String) -> PersistentFile
    var lifecycle: AppLifecycleSource
    var pushPlatform: PushPlatform
    var tokens: PushTokens
    var deviceInfo: DeviceInfo
    var timing: DeliveryTiming
    var tokenTimeout: Double
    /// How long `logout()` waits to send and detach.
    var logoutWait: Double = 5
    var now: @Sendable () -> Date
    var installPushIntegration: (Log) -> Void

    static func live(log: Log) -> KiroraEnvironment {
        let directory = StorageLocation.directory()
        let onError: @Sendable (Error) -> Void = { error in log.error("Couldn't save to the device", error) }
        #if canImport(UIKit) && !os(watchOS)
        let lifecycle: AppLifecycleSource = UIKitLifecycle()
        let platform: PushPlatform = UIKitPushPlatform()
        let installPushIntegration: (Log) -> Void = { PushIntegration.install(log: $0) }
        #else
        let lifecycle: AppLifecycleSource = NoLifecycle()
        let platform: PushPlatform = UnsupportedPushPlatform()
        let installPushIntegration: (Log) -> Void = { _ in }
        #endif
        return KiroraEnvironment(
            transport: URLSessionTransport(),
            store: FileKeyValueStore(file: PersistentFile(url: directory.appendingPathComponent("state.json"), onError: onError)),
            eventsFile: { namespace in
                PersistentFile(url: directory.appendingPathComponent("events-\(fileSafe(namespace)).json"), onError: onError)
            },
            lifecycle: lifecycle,
            pushPlatform: platform,
            tokens: .shared,
            deviceInfo: DeviceInfo(),
            timing: DeliveryTiming(),
            tokenTimeout: 30,
            now: { Date() },
            installPushIntegration: installPushIntegration
        )
    }
}

/// Where push isn't available.
struct UnsupportedPushPlatform: PushPlatform {
    var isSupported: Bool { false }
    func authorization() async -> PushAuthorization { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func registerForRemoteNotifications() async {}
    func firebaseToken() async -> String? { nil }
}

/// The latest client's `handleDeepLink`. Taps reach the SDK through iOS, not a client, so
/// the client created last speaks for the app.
let deepLinkHandler = Locked<(@MainActor @Sendable (URL) -> Bool)?>(nil)

/// A file name for a workspace's namespace (`kirora_pk_…@api.kirora.io`): a stable hash, so
/// no key or host characters end up in a path.
func fileSafe(_ namespace: String) -> String {
    // FNV-1a, 64-bit: stable across launches, unlike `hashValue`.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in namespace.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}
