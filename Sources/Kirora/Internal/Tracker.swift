import Foundation

let sessionStartedEvent = "Session Started"
let screenViewedEvent = "Screen Viewed"

/// A visit ends after 30 minutes without activity.
let sessionTimeout: Double = 30 * 60
/// How often the foreground keeps its visit alive: well inside the timeout.
let sessionKeepAlive: Double = 5 * 60

/// Tracking consent. With `requireTrackingConsent`, nothing is tracked until the user says
/// yes; without it, until they say no. The answer is remembered on the device.
struct TrackingConsent: Sendable {
    let store: KeyValueStore
    let required: Bool

    var allowed: Bool {
        let answer = store.string(StorageKeys.trackingConsent)
        return required ? answer == "granted" : answer != "refused"
    }

    /// The user said no, as opposed to not having answered yet.
    var refused: Bool { store.string(StorageKeys.trackingConsent) == "refused" }

    /// Records the answer. True if tracking has just become allowed.
    func answer(_ granted: Bool) -> Bool {
        let newlyAllowed = granted && !allowed
        store.set(granted ? "granted" : "refused", for: StorageKeys.trackingConsent)
        return newlyAllowed
    }
}

/// The current visit, kept in device storage so a relaunch continues it. Read once and kept
/// in memory; written when a visit starts, when the app goes to the background, and at most
/// once a minute otherwise: a minute is nothing against the 30-minute timeout.
final class Sessions: @unchecked Sendable {
    private struct Stored: Codable, Equatable {
        var sessionId: String
        var lastActivityAt: Int64
    }

    /// The visit as last recorded, and when it was last written.
    private struct State {
        var loaded = false
        var current: Stored?
        var writtenAt: Int64 = 0
    }

    private static let writeEvery: Int64 = 60_000

    private let store: KeyValueStore
    private let now: @Sendable () -> Date
    private let state = Locked(State())

    init(store: KeyValueStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    /// Records activity on the current visit. `started` is true if a new one began.
    func touch() -> (sessionId: String, started: Bool) {
        state.withLock { state in
            let live = liveSessionId(&state)
            let sessionId = live ?? newId()
            record(sessionId, &state, writeNow: live == nil)
            return (sessionId, live == nil)
        }
    }

    /// Extends the current visit without starting one, so time in the foreground never
    /// ends a visit but a timer alone never begins one. `writeNow` before suspension.
    func keepAlive(writeNow: Bool = false) {
        state.withLock { state in
            if let sessionId = liveSessionId(&state) { record(sessionId, &state, writeNow: writeNow) }
        }
    }

    func end() {
        state.withLock { state in
            state = State(loaded: true)
            store.set(nil, for: StorageKeys.session)
        }
    }

    private func record(_ sessionId: String, _ state: inout State, writeNow: Bool) {
        let at = epochMs(now())
        state.current = Stored(sessionId: sessionId, lastActivityAt: at)
        if writeNow || at - state.writtenAt >= Self.writeEvery {
            store.setJSON(state.current, for: StorageKeys.session)
            state.writtenAt = at
        }
    }

    private func liveSessionId(_ state: inout State) -> String? {
        if !state.loaded {
            state.current = store.json(Stored.self, StorageKeys.session)
            state.loaded = true
        }
        guard let current = state.current else { return nil }
        let idle = Double(epochMs(now()) - current.lastActivityAt) / 1000
        return idle < sessionTimeout ? current.sessionId : nil
    }
}

/// Turns what the app tracks into queued events: their time, visit and device, owned by
/// whoever is signed in. Nothing is recorded without tracking consent, and nothing here
/// throws: a failure is logged, so it never breaks the app.
///
/// Everything runs on the caller's thread under one lock, so events are queued in the
/// order they're tracked, with the user signed in at that moment.
final class Tracker: @unchecked Sendable {
    private let identity: Identity
    private let queue: EventQueue
    private let consent: TrackingConsent
    private let sessions: Sessions
    private let deviceId: DeviceId
    private let deviceInfo: DeviceInfo
    private let trackSessions: Bool
    private let log: Log
    private let now: @Sendable () -> Date
    private let onQueued: @Sendable (Int) -> Void
    private let lock = NSLock()

    init(
        identity: Identity,
        queue: EventQueue,
        consent: TrackingConsent,
        sessions: Sessions,
        deviceId: DeviceId,
        deviceInfo: DeviceInfo,
        trackSessions: Bool,
        log: Log,
        now: @escaping @Sendable () -> Date,
        onQueued: @escaping @Sendable (Int) -> Void
    ) {
        self.identity = identity
        self.queue = queue
        self.consent = consent
        self.sessions = sessions
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo
        self.trackSessions = trackSessions
        self.log = log
        self.now = now
        self.onQueued = onQueued
    }

    /// Builds the event right away so its time is accurate, then queues it.
    func track(_ name: String, properties: [String: JSONValue]) {
        guard !name.isEmpty else {
            log.error("Not tracked: an event needs a name")
            return
        }
        exclusively {
            guard consent.allowed else { return }
            let sessionId = touchSession()
            enqueue(name, properties, sessionId)
        }
    }

    /// Activity keeps the visit alive, or starts a new one with `Session Started`.
    func noteActivity() {
        exclusively {
            guard consent.allowed else { return }
            _ = touchSession()
        }
    }

    /// Extends the current visit without starting one, e.g. while in the foreground.
    /// `writeNow` as the app goes to the background.
    func keepSessionAlive(writeNow: Bool = false) {
        exclusively {
            if trackSessions, consent.allowed { sessions.keepAlive(writeNow: writeNow) }
        }
    }

    /// Tracks the events `build` makes, building them only if tracking is allowed: building
    /// may store state (the app's version, for lifecycle events), which consent covers too.
    func trackAll(_ build: () -> [(String, [String: JSONValue])]) {
        exclusively {
            guard consent.allowed else { return }
            for (name, properties) in build() {
                let sessionId = touchSession()
                enqueue(name, properties, sessionId)
            }
        }
    }

    /// Forgets queued events and the visit, as when consent is withdrawn; if `condition`
    /// holds, checked under the same lock as tracking, so an event tracked right after
    /// consent is granted is never forgotten with the rest.
    @discardableResult
    func forget(if condition: () -> Bool = { true }) -> Bool {
        var forgot = false
        exclusively {
            guard condition() else { return }
            queue.clearAll()
            sessions.end()
            forgot = true
        }
        return forgot
    }

    private func exclusively(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    /// The visit's id, if visits are on, starting one if needed.
    private func touchSession() -> String? {
        guard trackSessions else { return nil }
        let (sessionId, started) = sessions.touch()
        // Mobile SDKs track `Session Started` without properties.
        if started { enqueue(sessionStartedEvent, [:], sessionId) }
        return sessionId
    }

    /// Queues as the current user (if any), then lets delivery decide when to send.
    private func enqueue(_ name: String, _ properties: [String: JSONValue], _ sessionId: String?) {
        let event = QueuedEvent(
            idempotencyKey: newId(),
            name: name,
            properties: properties,
            occurredAt: isoTimestamp(now()),
            context: EventContext(
                sessionId: sessionId,
                // Will let Kirora link activity from before sign-in to the user later.
                device: .init(id: deviceId.value()),
                locale: deviceInfo.locale(),
                timezone: deviceInfo.timezone()
            )
        )
        let waiting = queue.add(event, owner: identity.user?.subject)
        log.debug("Queued \(name)")
        onQueued(waiting)
    }
}
