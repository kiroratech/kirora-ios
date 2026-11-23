import Foundation
@testable import Kirora

/// A user token naming `sub`, as the customer's server signs it (the SDK never checks the
/// signature: Kirora does).
/// Valid for the hour after `issuedAt`; by default, from just before the test clock's time.
func userToken(_ sub: String?, issuedAt: Int = 1_799_999_000, expiresIn: Int = 3600) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    var claims: [String: Any] = ["iat": issuedAt, "exp": issuedAt + expiresIn]
    if let sub { claims["sub"] = sub }
    return "\(encode(["alg": "HS256", "typ": "JWT"])).\(encode(claims)).signature"
}

/// A request the fake Kirora received.
struct SentRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: JSONValue?

    var token: String? { headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) } }
    var events: [JSONValue] {
        if case .array(let events)? = body?["events"] { return events }
        return []
    }
    var eventNames: [String] { events.compactMap { $0["name"]?.stringValue } }
    /// The `deviceSecret` a `PUT /devices` was sent with.
    var deviceSecret: String? { body?["deviceSecret"]?.stringValue }
}

/// What the fake answers.
struct FakeAnswer: Sendable {
    var status: Int
    var body: JSONValue?
    var headers: [String: String] = [:]
    /// Throws a network error instead of answering.
    var offline = false
    /// Answers after this many seconds, as a slow network would.
    var delay: Double = 0

    static func ok(_ data: JSONValue? = nil) -> FakeAnswer {
        FakeAnswer(status: 200, body: data.map { .object(["data": $0]) })
    }
    static let noContent = FakeAnswer(status: 204, body: nil)
    static let networkError = FakeAnswer(status: 0, body: nil, offline: true)
    /// Kirora's 400 for a request whose body (or `in`) fields are invalid, naming each.
    static func validationError(fields: [String], in part: String = "body", status: Int = 400) -> FakeAnswer {
        let errors = fields.map { field -> JSONValue in
            .object(["in": .string(part), "field": .string(field), "code": .string("custom"), "message": .string("invalid")])
        }
        return FakeAnswer(status: status, body: .object(["error": .object([
            "code": .string("VALIDATION_ERROR"), "message": .string("invalid"), "errors": .array(errors),
        ])]))
    }

    static func error(_ status: Int, _ code: String, retryAfter: String? = nil) -> FakeAnswer {
        FakeAnswer(
            status: status,
            body: .object(["error": .object(["code": .string(code), "message": .string("refused")])]),
            headers: retryAfter.map { ["Retry-After": $0] } ?? [:]
        )
    }
}

/// Kirora's `/client/v1`, faked: records every call and answers as scripted, by default as
/// Kirora would for a healthy workspace with one iOS push app.
final class FakeKirora: HTTPTransport, @unchecked Sendable {
    static let pushAppId = "7f1c9c2e-6a0b-4d3c-9a43-2d1f0f6f1e11"

    private let state = Locked<(requests: [SentRequest], handler: (@Sendable (SentRequest) -> FakeAnswer?)?)>(([], nil))

    var requests: [SentRequest] { state.withLock { $0.requests } }
    private let completed = Locked<[SentRequest]>([])
    /// Requests answered, as opposed to cancelled while waiting for the answer.
    var completedRequests: [SentRequest] { completed.current }

    func requests(_ method: String, _ path: String) -> [SentRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    var batches: [SentRequest] { requests("POST", "/client/v1/events/batch") }
    var sentEventNames: [String] { batches.flatMap(\.eventNames) }
    /// The names of the events sent with `subject`'s token.
    func eventNames(sentAs subject: String) -> [String] {
        batches.filter { subjectOf($0.token ?? "") == subject }.flatMap(\.eventNames)
    }

    /// Answers calls `handler` returns an answer for; the rest as by default.
    func answer(_ handler: @escaping @Sendable (SentRequest) -> FakeAnswer?) {
        state.withLock { $0.handler = handler }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let sent = SentRequest(
            method: request.httpMethod ?? "GET", path: components.path, query: query,
            headers: request.allHTTPHeaderFields ?? [:], body: body
        )
        let handler = state.withLock { state -> (@Sendable (SentRequest) -> FakeAnswer?)? in
            state.requests.append(sent)
            return state.handler
        }
        let answer = handler?(sent) ?? Self.defaultAnswer(sent)
        if answer.delay > 0 { try await Task.sleep(nanoseconds: UInt64(answer.delay * 1_000_000_000)) }
        completed.withLock { $0.append(sent) }
        if answer.offline { throw URLError(.notConnectedToInternet) }
        let data = try answer.body.map { try JSONEncoder().encode($0) } ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (data, response)
    }

    static func defaultAnswer(_ request: SentRequest) -> FakeAnswer {
        switch (request.method, request.path) {
        case ("POST", "/client/v1/events/batch"):
            let results = request.events.map { event -> JSONValue in
                .object(["idempotencyKey": event["idempotencyKey"] ?? .null, "replayed": .bool(false), "event": recordedEvent])
            }
            return .ok(.object(["results": .array(results)]))
        case ("GET", "/client/v1/push-app"):
            return .ok(.object([
                "pushAppId": .string(pushAppId), "name": .string("iOS"),
                "targetKind": .string("apns_token"), "vapidPublicKey": .null,
            ]))
        case ("PUT", _) where request.path.hasPrefix("/client/v1/devices/"):
            return FakeAnswer(status: 201, body: .object(["data": .object(["lastSeenAt": .string("2026-11-13T10:00:00.000Z")])]))
        default:
            return .noContent
        }
    }
}

/// The app's lifecycle, driven by the test.
final class ManualLifecycle: AppLifecycleSource, @unchecked Sendable {
    private let handler = Locked<(@Sendable (LifecycleEvent) -> Void)?>(nil)
    let backgroundWork = Locked(0)

    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) { self.handler.withLock { $0 = handler } }
    func stop() { handler.withLock { $0 = nil } }
    func runInBackground(_ name: String, _ work: @escaping @Sendable () async -> Void) {
        backgroundWork.withLock { $0 += 1 }
        Task { await work() }
    }

    func fire(_ event: LifecycleEvent) { handler.withLock { $0 }?(event) }
}

/// The OS's notification permission and APNs, faked.
final class FakePushPlatform: PushPlatform, @unchecked Sendable {
    let status = Locked(PushAuthorization.authorized)
    /// What the prompt answers.
    let promptAnswer = Locked<PushAuthorization>(.authorized)
    let tokens: PushTokens
    /// The token iOS gives when asked; nil gives none.
    let apnsToken = Locked<Data?>(Data([0xAB, 0xCD, 0x01]))
    let registrations = Locked(0)

    init(tokens: PushTokens) { self.tokens = tokens }

    var isSupported: Bool { true }
    func authorization() async -> PushAuthorization { status.current }
    func requestAuthorization() async throws -> Bool {
        let answer = promptAnswer.current
        status.withLock { $0 = answer }
        return answer == .authorized
    }
    /// Firebase's token, when the app includes Firebase.
    let fcmToken = Locked<String?>(nil)
    /// Firebase's installation id, when the app is in Firebase's installation-id mode.
    let firebaseInstallationId = Locked<String?>(nil)
    func firebaseTarget() async -> PushTarget? {
        if let id = firebaseInstallationId.current { return PushTarget(kind: firebaseInstallationIdKind, token: id) }
        return fcmToken.current.map { PushTarget(kind: fcmTokenKind, token: $0) }
    }
    func registerForRemoteNotifications() async {
        registrations.withLock { $0 += 1 }
        if let token = apnsToken.current { tokens.received(token) }
    }
}

final class TestClock: @unchecked Sendable {
    private let date = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.current }
    func advance(_ seconds: Double) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// One client and everything it runs on, so a test can restart the app with the same
/// device storage.
final class TestApp: @unchecked Sendable {
    let kirora = Locked<Kirora?>(nil)
    let server = FakeKirora()
    let store = MemoryKeyValueStore()
    /// The second copy of a tracking refusal.
    let refusals = MemoryKeyValueStore()
    let clock = TestClock()
    let lifecycle = ManualLifecycle()
    let tokens = PushTokens()
    lazy var push = FakePushPlatform(tokens: tokens)
    let directory: URL
    var deviceInfo = DeviceInfo(
        appName: { "Shop" }, bundleId: { "com.example.shop" },
        screen: { DeviceInfo.Screen(width: 393, height: 852, density: 3) },
        appVersion: { "2.4.0" }, appBuild: { "412" }, osVersion: { "17.4.1" },
        locale: { "en-GB" }, timezone: { "Africa/Lagos" }
    )
    var timing = DeliveryTiming(flushAtEvents: 20, flushInterval: 0.05, maxRetryDelay: 0.2)
    var logoutWait: Double = 5

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        kirora.current?.destroy()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Where the client keeps `key` in the app's store.
    func scopedKey(_ key: String, clientKey: String = "kirora_pk_test") -> String {
        StorageKeys.scoped.contains(key) ? StorageKeys.scoped(key, "\(clientKey)@api.test.kirora.io") : key
    }

    /// What the client has stored under `key`.
    func stored(_ key: String, clientKey: String = "kirora_pk_test") -> String? {
        store.string(scopedKey(key, clientKey: clientKey))
    }

    /// Starts (or restarts) the client.
    @discardableResult
    func start(
        clientKey: String = "kirora_pk_test",
        fetchUserToken: (@Sendable () async throws -> String?)? = nil,
        onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)? = nil,
        push: KiroraPushOptions? = nil,
        requireTrackingConsent: Bool = false,
        trackSessions: Bool = true,
        trackAppLifecycle: Bool = false,
        tokenTimeout: Double = 30,
        apiUrl: String = "https://api.test.kirora.io",
        beforeSend: (@Sendable (BeforeSendEvent) throws -> BeforeSendEvent?)? = nil
    ) -> Kirora {
        kirora.current?.destroy()
        let clock = self.clock
        let directory = self.directory
        var environment = KiroraEnvironment(
            transport: server, store: store, refusals: refusals,
            eventsFile: { namespace in
                PersistentFile(url: directory.appendingPathComponent("events-\(fileSafe(namespace)).json"), onError: { _ in })
            },
            lifecycle: lifecycle, pushPlatform: self.push, tokens: tokens, deviceInfo: deviceInfo,
            timing: timing, tokenTimeout: tokenTimeout, now: { clock.now }, installPushIntegration: { _ in }
        )
        environment.logoutWait = logoutWait
        let client = Kirora(
            options: KiroraOptions(
                clientKey: clientKey, fetchUserToken: fetchUserToken,
                onAuthenticationFailed: onAuthenticationFailed, push: push,
                requireTrackingConsent: requireTrackingConsent, trackSessions: trackSessions,
                trackAppLifecycle: trackAppLifecycle, logLevel: .none, apiUrl: apiUrl,
                beforeSend: beforeSend
            ),
            environment: environment
        )
        kirora.withLock { $0 = client }
        return client
    }
}

/// Waits up to `seconds` for `condition`, for work the SDK does in the background.
func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await sleep(seconds: 0.01)
    }
    return condition()
}

/// Lets background work that should *not* happen have its chance to.
func settle(_ seconds: Double = 0.15) async {
    await sleep(seconds: seconds)
}

/// What a failing `fetchUserToken` throws in tests.
struct TokenServerDown: Error {}

/// The tests' `apiUrl`, which push reports must be on.
let testApiBase = URL(string: "https://api.test.kirora.io")!

/// What Kirora answers for an event it recorded (`TrackedEvent`).
let recordedEvent: JSONValue = .object([
    "id": .string("00000000-0000-4000-8000-000000000000"),
    "occurredAt": .string("2026-11-17T00:00:00.000Z"),
    "expiresAt": .string("2027-11-17T00:00:00.000Z"),
])
