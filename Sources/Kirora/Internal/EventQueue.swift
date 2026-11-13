import Foundation

/// As `POST /events/batch` takes it. The idempotency key, fixed when the event is queued,
/// makes resends safe.
struct QueuedEvent: Codable, Sendable, Equatable {
    var idempotencyKey: String
    var name: String
    var properties: [String: JSONValue]
    var occurredAt: String
    var context: EventContext
}

/// Where and on what an event happened. Only the fields `api/events.md` lists: Kirora
/// refuses any other.
struct EventContext: Codable, Sendable, Equatable {
    struct Device: Codable, Sendable, Equatable { var id: String }

    var sessionId: String?
    var device: Device
    var locale: String?
    var timezone: String?
}

/// Who an event belongs to: the signed-in user's token subject when it was tracked, or nil
/// before sign-in. Kept on the device only, never sent.
private struct StoredEvent: Codable, Sendable {
    var owner: String?
    var event: QueuedEvent
}

/// Past this many, the oldest events are dropped (e.g. after a long time offline).
let maxQueuedEvents = 1000

/// Events waiting to be sent, kept in a file so they survive the app being killed. One
/// queue per workspace.
///
/// Events tracked before sign-in go as whoever signs in next. An event tracked while a user
/// was signed in only ever goes as that user.
///
/// The file is read off the caller's thread, so creating the client never waits on the
/// disk. Events tracked before it's read are kept after those read; anything that reads or
/// removes events waits for it. The read happens on the file's own queue, after any write
/// an earlier client asked for, so a client never loses another's events.
final class EventQueue: @unchecked Sendable {
    private struct State {
        var stored: [StoredEvent] = []
        var loaded = false
    }

    private let file: PersistentFile
    private let state = Locked(State())

    init(file: PersistentFile) {
        self.file = file
        file.readSoon { data in self.load(data) }
    }

    /// Queues `event`, dropping the oldest past the limit. Returns how many `owner` may
    /// send now, leaving out other users' events, which can't go in their batch.
    @discardableResult
    ///
    /// Never waits for the file: before it's read, the read writes what was added meanwhile
    /// together with what it read, so the file never holds less than it did.
    func add(_ event: QueuedEvent, owner: String?) -> Int {
        state.withLock { state in
            state.stored.append(StoredEvent(owner: owner, event: event))
            if state.stored.count > maxQueuedEvents { state.stored.removeFirst(state.stored.count - maxQueuedEvents) }
            if state.loaded { persist() }
            return state.stored.lazy.filter { sendable($0, by: owner) }.count
        }
    }

    /// The oldest events `owner` may send: their own, and those from before sign-in.
    func oldest(_ count: Int, owner: String?) -> [QueuedEvent] {
        loadIfNeeded()
        return state.withLock { state in
            Array(state.stored.lazy.filter { sendable($0, by: owner) }.prefix(count).map(\.event))
        }
    }

    func remove(_ idempotencyKeys: Set<String>) {
        guard !idempotencyKeys.isEmpty else { return }
        keep { !idempotencyKeys.contains($0.event.idempotencyKey) }
    }

    /// Forgets what `owner` could send: their events and those from before sign-in.
    func clear(owner: String?) {
        keep { !sendable($0, by: owner) }
    }

    /// Forgets the events `test` picks of those with an owner, leaving those from before
    /// sign-in to whoever's next.
    func clearOwned(where test: (String, QueuedEvent) -> Bool) {
        keep { stored in
            guard let owner = stored.owner else { return true }
            return !test(owner, stored.event)
        }
    }

    func clearAll() {
        keep { _ in false }
    }

    /// Removes what `test` rejects, writing only if that was anything.
    private func keep(_ test: (StoredEvent) -> Bool) {
        loadIfNeeded()
        state.withLock { state in
            let before = state.stored.count
            state.stored.removeAll { !test($0) }
            if state.stored.count != before, state.loaded { persist() }
        }
    }

    private func loadIfNeeded() {
        if !state.withLock({ $0.loaded }) { file.readNow { load($0) } }
    }

    /// On the file's queue: takes the events read, once, keeping those tracked meanwhile
    /// after them, and writes the two together at once.
    private func load(_ data: Data?) {
        if state.withLock({ $0.loaded }) { return }
        // Unreadable entries are skipped rather than losing the whole queue to them.
        let decoded = (data.flatMap { try? JSONDecoder().decode([Lenient].self, from: $0) } ?? []).compactMap(\.value)
        let merged = state.withLock { state -> [StoredEvent]? in
            guard !state.loaded else { return nil }
            let trackedMeanwhile = state.stored
            state.stored = Array((decoded + trackedMeanwhile).suffix(maxQueuedEvents))
            state.loaded = true
            return trackedMeanwhile.isEmpty ? nil : state.stored
        }
        if let merged, let data = try? JSONEncoder().encode(merged) { file.writeNow(data) }
    }

    /// Writes the queue soon, as it stands when the write runs: a burst of changes costs
    /// one copy and one write, and nothing is copied on the caller's thread.
    private func persist() {
        file.write {
            let stored = self.state.withLock { $0.stored }
            return stored.isEmpty ? nil : try? JSONEncoder().encode(stored)
        }
    }

    /// One entry of the stored queue, or nil if it can't be read.
    private struct Lenient: Decodable {
        let value: StoredEvent?
        init(from decoder: Decoder) throws {
            value = try? StoredEvent(from: decoder)
        }
    }
}

/// An owner may send their own events and those from before sign-in.
private func sendable(_ stored: StoredEvent, by owner: String?) -> Bool {
    stored.owner == nil || stored.owner == owner
}
