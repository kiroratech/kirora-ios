import Foundation

/// What the OS says about notifications for this app.
enum PushAuthorization: Sendable, Equatable {
    /// Allowed, including provisional and ephemeral authorization.
    case authorized
    case denied
    case notDetermined
}

/// The OS's side of push, so the registrar can be tested without UIKit.
protocol PushPlatform: Sendable {
    var isSupported: Bool { get }
    func authorization() async -> PushAuthorization
    /// Shows the prompt. True if the user allowed notifications.
    func requestAuthorization() async throws -> Bool
    /// Asks iOS for the APNs token, which arrives through ``PushTokens``.
    func registerForRemoteNotifications() async
    /// Firebase's registration token, for a push app that sends through Firebase. Nil when
    /// the app doesn't include FirebaseMessaging, or it has no token yet.
    func firebaseToken() async -> String?
}

/// The APNs device token, as iOS hands it to the app delegate. Process-wide, since iOS
/// gives one token per app, whichever Kirora client asks.
final class PushTokens: @unchecked Sendable {
    static let shared = PushTokens()

    private struct State {
        var latest: String?
        var waiting: [UUID: CheckedContinuation<String?, Never>] = [:]
        var observers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = Locked(State())

    /// The token iOS gave in this run of the app, if it has.
    var latest: String? { state.withLock { $0.latest } }

    func received(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let (waiting, observers, changed) = state.withLock { state in
            let changed = state.latest != token
            state.latest = token
            defer { state.waiting = [:] }
            return (Array(state.waiting.values), Array(state.observers.values), changed)
        }
        waiting.forEach { $0.resume(returning: token) }
        if changed { observers.forEach { $0() } }
    }

    /// Firebase made a new registration token.
    func firebaseTokenChanged() {
        let observers = state.withLock { Array($0.observers.values) }
        observers.forEach { $0() }
    }

    func failed() {
        let waiting = state.withLock { state -> [CheckedContinuation<String?, Never>] in
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        waiting.forEach { $0.resume(returning: nil) }
    }

    /// The token, waiting up to `timeout` for iOS to give it.
    func token(timeout: Double) async -> String? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> String?? in
                if let latest = state.latest { return .some(latest) }
                state.waiting[id] = continuation
                return .none
            }
            if case .some(let token) = ready { continuation.resume(returning: token); return }
            Task {
                await sleep(seconds: timeout)
                let expired = self.state.withLock { $0.waiting.removeValue(forKey: id) }
                expired?.resume(returning: nil)
            }
        }
    }

    /// Calls `observer` when iOS gives a new token. Returns what stops it.
    func observe(_ observer: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.observers[id] = observer }
        return { [weak self] in self?.state.withLock { _ = $0.observers.removeValue(forKey: id) } }
    }

}

/// What this device was last registered for push as. `config` says what it was made for,
/// so a change of push app option or device id registers again.
struct PushRegistrationRecord: Codable, Equatable {
    var userSubject: String
    var config: String
    var token: String
    /// `apns_token` or `fcm_token`, as Kirora said for the push app. Missing in records
    /// from before Firebase was supported, which were all APNs.
    var targetKind: String?
    var pushAppId: String
    /// `granted`, or `denied` once a revoked permission was reported.
    var permission: String
    /// From Kirora's answer: a denial report must name it.
    var lastSeenAt: String?
    /// When (epoch ms) it was registered.
    var at: Int64
}

/// Re-register at most daily for the same user, token and configuration.
private let registrationRefresh: Double = 24 * 60 * 60
let apnsTokenKind = "apns_token"
let fcmTokenKind = "fcm_token"

/// How long to wait for iOS to give the APNs token.
private let tokenWait: Double = 10
/// A detachment Kirora couldn't take is retried for this long at most: tokens last a day.
private let detachRetryLimit: Double = 24 * 60 * 60

/// Permission prompt and device registration with Kirora.
final class PushRegistrar: @unchecked Sendable {
    private let api: ClientAPI
    private let identity: Identity
    private let store: KeyValueStore
    private let options: PushOptions?
    private let deviceId: DeviceId
    private let deviceInfo: DeviceInfo
    private let platform: PushPlatform
    private let tokens: PushTokens
    private let log: Log
    private let now: @Sendable () -> Date
    private let recordKey: String
    /// The registration or detachment running now. Each waits for the one before, so
    /// Kirora hears them in order and the last asked for is the one it keeps.
    private let last = Locked<Task<Void, Never>?>(nil)
    /// A detachment retried in the background after `logout()`. `generation` counts each
    /// stop, so a detachment whose first attempt was under way when one came never schedules
    /// retries afterwards; `stopped` is for good, at `destroy()`.
    private let detachRetry = Locked<(task: Task<Void, Never>?, generation: Int, stopped: Bool)>((nil, 0, false))
    /// Detach retry timing, as events retry.
    private let timing: DeliveryTiming
    /// Called once the device is detached and its record cleared: the device id may then
    /// go, if consent was refused.
    private let onDetached: @Sendable () -> Void
    /// The record as last saved, read once.
    private let cachedRecord = Locked<PushRegistrationRecord??>(nil)

    init(
        api: ClientAPI, identity: Identity, store: KeyValueStore, options: PushOptions?,
        deviceId: DeviceId, deviceInfo: DeviceInfo, platform: PushPlatform, tokens: PushTokens,
        log: Log, timing: DeliveryTiming, now: @escaping @Sendable () -> Date,
        onDetached: @escaping @Sendable () -> Void = {}
    ) {
        self.timing = timing
        self.onDetached = onDetached
        self.api = api
        self.identity = identity
        self.store = store
        self.options = options
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo
        self.platform = platform
        self.tokens = tokens
        self.log = log
        self.now = now
        recordKey = StorageKeys.pushRegistration(api.namespace)
    }

    var enabled: Bool { options != nil && platform.isSupported }

    /// Whether Kirora has this device registered, so its id must be kept to detach it.
    var registered: Bool { record != nil }

    /// The push app `user` is registered with, for app opens, while permission stands.
    func pushAppId(for user: SignedInUser) -> String? {
        guard let record, record.userSubject == user.subject, record.permission == "granted" else { return nil }
        return record.pushAppId
    }

    func requestPermission() async -> PushPermission {
        guard enabled else { return .unsupported }
        let allowed: Bool
        do {
            allowed = try await platform.requestAuthorization()
        } catch {
            log.error("Couldn't ask for notification permission", error)
            return .unsupported
        }
        if allowed {
            do { try await register() } catch { log.error("Push registration failed", error) }
            return .granted
        }
        // iOS answers false both when the user says no and when they were never asked.
        switch await platform.authorization() {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .unanswered
        }
    }

    /// As ``register()``, in the background, logging a failure: for a new token, or the app
    /// coming back to the foreground (notifications turned off in Settings, a day-old
    /// registration).
    func registerInBackground() {
        guard identity.user != nil, enabled else { return }
        let log = self.log
        Task {
            do { try await self.register() } catch { log.error("Push registration failed", error) }
        }
    }

    /// Registers this device as the user signed in now, or reports that the user turned
    /// notifications off. Gives up as soon as someone else signs in.
    func register() async throws {
        guard let user = identity.user, enabled, !isStopped else { return }
        try await oneAtATime { try await self.register(as: user) }
    }

    /// Detaches this device from `user` at sign-out, and never fails the app's sign-out:
    /// if Kirora can't be reached (offline, 429, 5xx), it keeps trying in the background,
    /// holding the user's token in memory only. It stops once Kirora takes it or refuses
    /// the token, when anyone signs in (a new user's registration moves the device anyway),
    /// or after a day.
    func detach(_ user: SignedInUser) async {
        stopRetrying()
        let generation = detachRetry.withLock { $0.stopped ? nil : $0.generation }
        guard let generation else { return }
        guard case .retry(let firstError) = await attemptDetach(user) else { return }
        let giveUpAt = Date().addingTimeInterval(detachRetryLimit)
        let timing = self.timing, log = self.log
        detachRetry.withLock { retry in
            // Stopped while the first attempt was under way: no retries now.
            guard !retry.stopped, retry.generation == generation else { return }
            retry.task = Task { [weak self] in
                var backoff = Backoff(timing)
                var retryAt = backoff.failed(firstError)
                while retryAt < giveUpAt {
                    await sleep(seconds: retryAt.timeIntervalSinceNow)
                    guard !Task.isCancelled, let self, self.mayRetry(generation) else { return }
                    guard case .retry(let error) = await self.attemptDetach(user) else { return }
                    retryAt = backoff.failed(error)
                }
                log.error("Gave up detaching this device from the signed-out user's pushes")
            }
        }
    }

    /// Stops a detachment retried in the background, as a new registration does.
    func stopRetrying() {
        detachRetry.withLock { retry in
            retry.task?.cancel()
            retry.task = nil
            retry.generation += 1
        }
    }

    /// Stops for good, at `destroy()`: no registration, detachment or retry starts after.
    func stop() {
        detachRetry.withLock { $0.stopped = true }
        stopRetrying()
    }

    private var isStopped: Bool { detachRetry.withLock { $0.stopped } }

    private func mayRetry(_ generation: Int) -> Bool {
        detachRetry.withLock { !$0.stopped && $0.generation == generation }
    }

    private enum DetachOutcome {
        case done
        /// Try again: Kirora couldn't be reached, or asked to wait.
        case retry(Error)
    }

    private func attemptDetach(_ user: SignedInUser) async -> DetachOutcome {
        let outcome = Locked(DetachOutcome.done)
        try? await oneAtATime {
            guard !self.isStopped else { return }
            // Only this user's registration is theirs to detach. Once anyone signs in, their
            // registration decides where the device's pushes go.
            guard self.record?.userSubject == user.subject else { return }
            if let current = self.identity.user, current !== user { return }
            do {
                try await self.api.request("DELETE", "/devices/\(self.deviceId.value())", as: user)
                self.save(nil)
                self.log.debug("Detached this device from the user's pushes")
                self.onDetached()
            } catch let error as KiroraApiError where !error.isRetryable {
                // Refused for good (e.g. the token, with no fresh one to be had). The record
                // stays: Kirora may still have the device, so its id must be kept.
                self.log.error("Couldn't detach this device from the user's pushes", error)
            } catch {
                self.log.error("Couldn't detach this device yet; retrying in the background", error)
                outcome.withLock { $0 = .retry(error) }
            }
        }
        return outcome.current
    }

    private func register(as user: SignedInUser) async throws {
        let current = { self.identity.user === user }
        guard current() else { return }
        // A signed-in user's registration supersedes any detachment still being retried.
        stopRetrying()
        switch await platform.authorization() {
        case .notDetermined:
            return
        case .denied:
            try await reportDenied(as: user)
            return
        case .authorized:
            break
        }
        // Firebase needs the APNs token too, to make its own. Asked for once a run: a token
        // iOS changes later arrives through `PushTokens` and registers again.
        if tokens.latest == nil { await platform.registerForRemoteNotifications() }
        let apnsToken: String?
        if let fresh = await tokens.token(timeout: tokenWait) {
            apnsToken = fresh
            store.set(fresh, for: StorageKeys.apnsToken)
        } else {
            // iOS is slow to answer; last launch's token is almost always still right.
            apnsToken = store.string(StorageKeys.apnsToken)
        }
        let config = self.config()
        // A signed-in start costs no push calls: the kind of token comes from the last
        // registration while it's fresh, and from Kirora otherwise.
        if let record, isFresh(record, user: user, config: config) {
            let kind = record.targetKind ?? apnsTokenKind
            if await self.token(of: kind, apnsToken: apnsToken) == record.token || !current() { return }
        }
        guard current(), let pushApp = try await choosePushApp(as: user), current() else { return }
        guard let token = await self.token(of: pushApp.targetKind, apnsToken: apnsToken) else {
            log.error(pushApp.targetKind == fcmTokenKind
                ? "This push app sends through Firebase, but the app has no Firebase token. Add FirebaseMessaging and configure Firebase"
                : "iOS gave no APNs token. Is the Push Notifications capability on?")
            return
        }
        var body = deviceInfo.registrationDetails()
        body["pushAppId"] = .string(pushApp.pushAppId)
        body["targetKind"] = .string(pushApp.targetKind)
        body["permission"] = .string("granted")
        body["target"] = .string(token)
        let answer = try await api.request("PUT", "/devices/\(deviceId.value())", body: JSONValue.object(body), as: user)
        // Saved even if the user changed meanwhile: it records who Kirora now has, so the
        // next user's registration (queued behind this one) isn't skipped as fresh.
        save(PushRegistrationRecord(
            userSubject: user.subject, config: config, token: token, targetKind: pushApp.targetKind,
            pushAppId: pushApp.pushAppId, permission: "granted",
            lastSeenAt: answer?["lastSeenAt"]?.stringValue, at: epochMs(now())
        ))
        log.debug("Registered this device for push")
    }

    /// The token of the kind Kirora asked for.
    private func token(of kind: String, apnsToken: String?) async -> String? {
        kind == fcmTokenKind ? await platform.firebaseToken() : apnsToken
    }

    /// Notifications are off: tell Kirora, so it stops sending, naming the registration it
    /// saw last so a stale report can't undo a newer one. Sent when the user turned them off
    /// in Settings, and when a different user signs in on a device registered for someone
    /// else: the report moves the device to them, so it stops taking the earlier user's
    /// pushes.
    private func reportDenied(as user: SignedInUser) async throws {
        guard var record, record.userSubject != user.subject || record.permission == "granted" else { return }
        var body = deviceInfo.registrationDetails()
        body["pushAppId"] = .string(record.pushAppId)
        body["permission"] = .string("denied")
        body["lastSeenAt"] = .string(record.lastSeenAt ?? isoTimestamp(Date(timeIntervalSince1970: Double(record.at) / 1000)))
        do {
            let answer = try await api.request("PUT", "/devices/\(deviceId.value())", body: JSONValue.object(body), as: user)
            record.lastSeenAt = answer?["lastSeenAt"]?.stringValue ?? record.lastSeenAt
        } catch let error as KiroraApiError where error.status == 409 || error.status == 404 {
            // 409: Kirora has a registration newer than the one the SDK last saw, and this
            // was already the latest `lastSeenAt` it has, so sending again would only be
            // refused again; that registration decides. 404: the device was never
            // registered in this push app, so there's nothing to turn off.
            log.debug("Denial not reported: Kirora answered \(error.status)")
        }
        record.userSubject = user.subject
        record.permission = "denied"
        record.at = epochMs(now())
        save(record)
    }

    /// Asks Kirora which push app to use. Nil, logged, if none is set up.
    private func choosePushApp(as user: SignedInUser) async throws -> (pushAppId: String, targetKind: String)? {
        var query = [URLQueryItem(name: "platform", value: "ios")]
        if let pushAppId = options?.pushAppId { query.append(URLQueryItem(name: "pushAppId", value: pushAppId)) }
        do {
            let answer = try await api.request("GET", "/push-app", query: query, as: user)
            guard let pushAppId = answer?["pushAppId"]?.stringValue else {
                log.error("Kirora's push app answer had no pushAppId")
                return nil
            }
            // Servers from before Firebase was supported on iOS only took APNs tokens.
            let targetKind = answer?["targetKind"]?.stringValue ?? apnsTokenKind
            guard targetKind == apnsTokenKind || targetKind == fcmTokenKind else {
                log.error("This push app takes \(targetKind) tokens, which iOS can't give")
                return nil
            }
            return (pushAppId, targetKind)
        } catch let error as KiroraApiError where error.status == 404 {
            log.error("No ready iOS push app in this workspace")
            return nil
        }
    }

    /// Registered for this user and configuration in the last day, with permission.
    private func isFresh(_ record: PushRegistrationRecord, user: SignedInUser, config: String) -> Bool {
        let age = Double(epochMs(now()) - record.at) / 1000
        return age >= 0 && age < registrationRefresh
            && record.userSubject == user.subject && record.config == config
            && record.permission == "granted"
    }

    private func config() -> String {
        "\(options?.pushAppId ?? "")|\(deviceId.value())"
    }

    private var record: PushRegistrationRecord? {
        cachedRecord.withLock { cached in
            if cached == nil { cached = .some(store.json(PushRegistrationRecord.self, recordKey)) }
            return cached ?? nil
        }
    }

    private func save(_ record: PushRegistrationRecord?) {
        cachedRecord.withLock { cached in
            cached = .some(record)
            store.setJSON(record, for: recordKey)
        }
    }

    private func oneAtATime(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let mine: Task<Void, Error> = last.withLock { last in
            let previous = last
            let task = Task {
                await previous?.value
                try await operation()
            }
            last = Task { _ = try? await task.value }
            return task
        }
        try await mine.value
    }
}
