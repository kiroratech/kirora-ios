import Foundation

/// Small values the SDK keeps on the device: `device.id`, the visit, consent, what was
/// last registered for push. Everything is in the app's own container, so it goes with an
/// uninstall.
protocol KeyValueStore: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func set(_ value: String?, for key: String)
}

extension KeyValueStore {
    func json<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        guard let text = string(key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setJSON<Value: Encodable>(_ value: Value?, for key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            set(nil, for: key)
            return
        }
        set(String(decoding: data, as: UTF8.self), for: key)
    }
}

/// Every key the SDK stores under. The README's "What the SDK stores" lists the same.
enum StorageKeys {
    /// `device.id`, also the device's installation id for push.
    static let deviceId = "device-id"
    /// The current visit: its id and last activity.
    static let session = "session"
    /// The user's tracking consent answer.
    static let trackingConsent = "tracking-consent"
    /// The app's version and build at the last launch, for lifecycle events.
    static let appVersion = "app-version"
    /// The last foreground activity, so app opens go at most once per 30 minutes.
    static let appOpenActivity = "app-open-activity"
    /// The APNs device token iOS last gave.
    static let apnsToken = "apns-token"
    /// Who this device was last registered for push as, per workspace.
    static func pushRegistration(_ namespace: String) -> String { "push-registration:\(namespace)" }
    /// App opens waiting to be reported, per workspace.
    static func appOpens(_ namespace: String) -> String { "app-opens:\(namespace)" }
}

/// Where the SDK's files live: `Application Support/io.kirora.sdk/`, left out of iCloud
/// and iTunes backups so a restored phone gets a `device.id` of its own.
enum StorageLocation {
    /// Where the files go. Only works out the path: the directory is made, and kept out of
    /// backups, by the first write, off the app's thread.
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("io.kirora.sdk", isDirectory: true)
    }
}

/// A file read and written in the background, the latest state winning: many changes in a
/// row cost one write, and the state is encoded there too, off the caller's thread.
///
/// Every client in the process uses one serial queue per file, so a client created after
/// another reads everything that one wrote, with no client waiting for its writes.
final class PersistentFile: @unchecked Sendable {
    /// Encodes the state to write, or nil to remove the file.
    typealias Contents = @Sendable () -> Data?

    let url: URL
    private let queue: DispatchQueue
    private let pending = Locked<Contents?>(nil)
    private let onError: @Sendable (Error) -> Void

    private static let queues = Locked<[String: DispatchQueue]>([:])

    init(url: URL, onError: @escaping @Sendable (Error) -> Void) {
        self.url = url
        self.onError = onError
        queue = Self.queues.withLock { queues in
            if let queue = queues[url.path] { return queue }
            let queue = DispatchQueue(label: "io.kirora.sdk.file.\(url.lastPathComponent)", qos: .utility)
            queues[url.path] = queue
            return queue
        }
    }

    /// Runs `body` on the file's queue with the file as it stands after every write asked
    /// for so far, by any client, and waits for it. `body` may call ``writeNow(_:)``.
    func readNow<Result>(_ body: (Data?) -> Result) -> Result {
        queue.sync { body(try? Data(contentsOf: url)) }
    }

    /// As ``readNow(_:)``, without waiting.
    func readSoon(_ body: @escaping @Sendable (Data?) -> Void) {
        queue.async { [url] in body(try? Data(contentsOf: url)) }
    }

    /// Writes at once. Only from a `readNow` or `readSoon` body, which runs on the queue, so
    /// it lands before anything read or written after.
    func writeNow(_ data: Data) {
        do {
            try Self.prepareDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic])
        } catch {
            onError(error)
        }
    }

    /// Writes what `contents` encodes, soon. Call it with a snapshot of the state.
    func write(_ contents: @escaping Contents) {
        let scheduled = pending.withLock { pending -> Bool in
            defer { pending = contents }
            return pending != nil
        }
        if scheduled { return }
        queue.async { [self] in
            guard let latest = pending.take() else { return }
            if let data = latest() {
                writeNow(data)
            } else if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch { onError(error) }
            }
        }
    }

    /// Waits for writes already asked for. Never on the app's own thread.
    func waitForWrites() {
        queue.sync {}
    }

    /// Waits for every file's writes, by every client, e.g. before the app is suspended.
    static func waitForAllWrites() {
        for queue in queues.withLock({ Array($0.values) }) { queue.sync {} }
    }

    /// Makes the directory, left out of iCloud and iTunes backups so a restored phone gets
    /// a `device.id` of its own.
    private static func prepareDirectory(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
    }
}

/// The SDK's small values, kept in memory and written to one JSON file. The file is read in
/// the background as the client starts; a value asked for before that has finished waits for
/// it (a few hundred bytes).
final class FileKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let file: PersistentFile
    private let values = Locked<[String: String]?>(nil)

    init(file: PersistentFile) {
        self.file = file
        file.readSoon { data in self.load(data) }
    }

    func string(_ key: String) -> String? {
        loadIfNeeded()
        return values.withLock { $0?[key] }
    }

    func set(_ value: String?, for key: String) {
        loadIfNeeded()
        values.withLock { values in
            guard values?[key] != value else { return }
            values?[key] = value
            // Encoded as they stand when the write runs, so a burst of changes is one write.
            file.write { try? JSONEncoder().encode(self.values.withLock { $0 } ?? [:]) }
        }
    }

    private func loadIfNeeded() {
        if values.withLock({ $0 == nil }) { file.readNow { load($0) } }
    }

    /// On the file's queue.
    private func load(_ data: Data?) {
        let decoded = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        values.withLock { values in
            if values == nil { values = decoded }
        }
    }
}

/// For tests, and for a client whose storage failed.
final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let values = Locked<[String: String]>([:])

    init() {}

    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    /// Every key stored, for tests that check what the SDK keeps.
    var keys: Set<String> { values.withLock { Set($0.keys) } }
}
