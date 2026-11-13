import Foundation
import Testing
@testable import Kirora

@Suite("Events and delivery")
struct DeliveryTests {
    @Test func anEventCarriesItsKeyTimeAndContext() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed", properties: ["order_id": "1042", "total": 46.5, "items": 2, "gift": false])
        await kirora.flush()
        let batch = try #require(app.server.batches.first)
        #expect(batch.body?["sentAt"]?.stringValue != nil)
        let event = try #require(batch.events.first { $0["name"]?.stringValue == "Order Completed" })
        #expect(event["idempotencyKey"]?.stringValue?.count == 36)
        #expect(event["occurredAt"]?.stringValue == isoTimestamp(app.clock.now))
        #expect(event["properties"] == .object([
            "order_id": .string("1042"), "total": .double(46.5), "items": .int(2), "gift": .bool(false),
        ]))
        let context = try #require(event["context"])
        #expect(context["device"]?["id"]?.stringValue == app.store.string(StorageKeys.deviceId))
        #expect(context["locale"] == .string("en-GB"))
        #expect(context["timezone"] == .string("Africa/Lagos"))
        #expect(context["sessionId"]?.stringValue != nil)
        // Only the fields Kirora's context takes.
        if case .object(let fields) = context {
            #expect(Set(fields.keys).isSubset(of: ["sessionId", "device", "locale", "timezone"]))
        }
    }

    @Test func screenViewsNameTheScreen() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        kirora.trackScreenView("Checkout")
        await kirora.flush()
        let event = try #require(app.server.batches.flatMap(\.events).first { $0["name"] == .string("Screen Viewed") })
        #expect(event["properties"] == .object(["name": .string("Checkout")]))
    }

    @Test func sendsAtOnceWhen20Wait() async throws {
        let app = TestApp()
        app.timing.flushInterval = 60
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("user-1"))
        await settle()
        for index in 0..<20 { kirora.track("Event \(index)") }
        #expect(await eventually { app.server.sentEventNames.count == 20 })
    }

    @Test func sendsOnATimerOtherwise() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        kirora.track("One")
        #expect(await eventually { app.server.sentEventNames.contains("One") })
    }

    @Test func sendsInBatchesOf100() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        for index in 0..<250 { kirora.track("Event \(index)") }
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(await eventually { app.server.sentEventNames.count == 250 })
        #expect(app.server.batches.map(\.events.count).max() == 100)
    }

    @Test func aRefusedEventIsDroppedAndTheRestGo() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        app.server.answer { request in
            guard request.path.hasSuffix("/events/batch") else { return nil }
            let results = request.events.map { event -> JSONValue in
                event["name"] == .string("contact.bad")
                    ? .object(["idempotencyKey": event["idempotencyKey"]!, "error": .object(["code": .string("VALIDATION_ERROR")])])
                    : .object(["idempotencyKey": event["idempotencyKey"]!, "replayed": .bool(false)])
            }
            return .ok(.object(["results": .array(results)]))
        }
        try await kirora.identify(userToken("user-1"))
        kirora.track("contact.bad")
        kirora.track("Good")
        await kirora.flush()
        await kirora.flush()
        // Settled at the first answer: never resent.
        #expect(app.server.batches.count == 1)
    }

    @Test func aServerErrorKeepsEventsForARetry() async throws {
        let app = TestApp()
        let kirora = app.start()
        let failures = Locked(1)
        app.server.answer { request in
            guard request.path.hasSuffix("/events/batch") else { return nil }
            return failures.withLock { left in
                defer { left -= 1 }
                return left > 0 ? FakeAnswer.error(503, "UNAVAILABLE") : nil
            }
        }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        #expect(await eventually { app.server.batches.count == 2 })
        let first = try #require(app.server.batches.first?.events.last?["idempotencyKey"])
        #expect(app.server.batches.last?.events.last?["idempotencyKey"] == first)
    }

    @Test func neverRetriesSoonerThanRetryAfter() async throws {
        let app = TestApp()
        let kirora = app.start()
        app.server.answer { request in
            request.path.hasSuffix("/events/batch") ? .error(429, "RATE_LIMITED", retryAfter: "120") : nil
        }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        await kirora.flush()
        let tries = app.server.batches.count
        // A manual flush can skip the SDK's own backoff, never the server's.
        await kirora.flush()
        await settle(0.3)
        #expect(app.server.batches.count == tries)
    }

    @Test func aPlanWithoutCustomEventsDropsTheBatch() async throws {
        let app = TestApp()
        let kirora = app.start()
        app.server.answer { request in
            request.path.hasSuffix("/events/batch") ? .error(403, "PLAN_FEATURE_UNAVAILABLE") : nil
        }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        await kirora.flush()
        await kirora.flush()
        #expect(app.server.batches.count == 1)
    }

    @Test func anInvalidBatchIsSplitToFindTheBadEvent() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        app.server.answer { request in
            guard request.path.hasSuffix("/events/batch") else { return nil }
            return request.eventNames.contains("Bad") ? .error(400, "VALIDATION_ERROR") : nil
        }
        for name in ["A", "B", "Bad", "C"] { kirora.track(name) }
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(await eventually {
            Set(app.server.batches.filter { !$0.eventNames.contains("Bad") }.flatMap(\.eventNames)) == ["A", "B", "C"]
        })
    }

    @Test func eventsSurviveARestart() async throws {
        let app = TestApp()
        app.server.answer { _ in .networkError }
        let first = app.start()
        first.track("Before Restart")
        first.destroy()
        // The file is written in the background.
        await settle()
        app.server.answer { _ in nil }
        let second = app.start()
        try await second.identify(userToken("user-1"))
        await second.flush()
        #expect(app.server.sentEventNames.contains("Before Restart"))
    }

    @Test func aClientStartedStraightAfterAnotherSeesItsEvents() async throws {
        let app = TestApp()
        for index in 0..<5 {
            let client = app.start(trackSessions: false)
            client.track("Event \(index)")
            // No wait: the next client starts at once.
        }
        let last = app.start(trackSessions: false)
        try await last.identify(userToken("user-1"))
        await last.flush()
        #expect(Set(app.server.sentEventNames) == Set((0..<5).map { "Event \($0)" }))
    }

    @Test func theStateFileIsReadAndWrittenOffTheCallersThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let first = FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in }))
        first.set("a", for: "one")
        // A second store at once, as a new client would: it sees the first one's write.
        let second = FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in }))
        #expect(second.string("one") == "a")
        PersistentFile.waitForAllWrites()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func keepsAtMost1000Events() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        for index in 0..<1010 { kirora.track("Event \(index)") }
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(await eventually { app.server.sentEventNames.count == 1000 })
        #expect(app.server.sentEventNames.first == "Event 10")
    }

    @Test func aDestroyedClientTracksAndSendsNothing() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        let before = app.server.requests.count
        kirora.destroy()
        kirora.track("After Destroy")
        await kirora.flush()
        await settle()
        #expect(app.server.requests.count == before)
    }

    @Test func aBadApiUrlIsReportedAndSendsNothing() async throws {
        let server = FakeKirora()
        let identity = Identity(fetchUserToken: nil)
        let api = ClientAPI(clientKey: "kirora_pk_test", apiUrl: "not a url", identity: identity, transport: server)
        #expect(api.urlProblem != nil)
        try await identity.signIn(token: userToken("user-1")) {}
        await #expect(throws: KiroraError.self) { try await api.request("GET", "/push-app") }
        #expect(server.requests.isEmpty)
    }
}

@Suite("Properties")
struct PropertyTests {
    @Test func convertsWhatJSONCanHold() {
        var dropped: [String] = []
        let date = Date(timeIntervalSince1970: 0)
        let value = JSONValue.fromObject([
            "string": "a", "int": 3, "double": 1.5, "bool": true, "null": NSNull(),
            "date": date, "url": URL(string: "https://kirora.io")!,
            "nested": ["list": [1, "two", Optional<Int>.none as Any]],
            "nan": Double.nan, "object": NSObject(),
        ], dropped: &dropped)
        #expect(value["string"] == .string("a"))
        #expect(value["int"] == .int(3))
        #expect(value["double"] == .double(1.5))
        #expect(value["bool"] == .bool(true))
        #expect(value["null"] == .null)
        #expect(value["date"] == .string("1970-01-01T00:00:00.000Z"))
        #expect(value["url"] == .string("https://kirora.io"))
        #expect(value["nested"] == .object(["list": .array([.int(1), .string("two"), .null])]))
        #expect(value["nan"] == .null)
        #expect(value["object"] == nil)
        #expect(dropped == ["object"])
    }

    @Test func tellsBooleansFromNumbers() {
        var dropped: [String] = []
        #expect(JSONValue.from(NSNumber(value: true), dropped: &dropped) == .bool(true))
        #expect(JSONValue.from(NSNumber(value: 1), dropped: &dropped) == .int(1))
        #expect(JSONValue.from(NSNumber(value: 2.5), dropped: &dropped) == .double(2.5))
    }

    @Test func sleepingNeverTrapsOnAnyValue() async {
        await sleep(seconds: -1)
        await sleep(seconds: .nan)
        let longest = Task { await sleep(seconds: .infinity) }
        longest.cancel()
        await longest.value
    }

    @Test func readsRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(retryAfterMs("120", now: now) == 120_000)
        #expect(retryAfterMs(nil, now: now) == nil)
        #expect(retryAfterMs("0", now: now) == nil)
        // Never traps, whatever the server sends.
        #expect(retryAfterMs("99999999999999999999", now: now) == Int(maxWaitSeconds * 1000))
        #expect(retryAfterMs("inf", now: now) == nil)
        #expect(retryAfterMs("nan", now: now) == nil)
        #expect(retryAfterMs("-5", now: now) == nil)
        #expect(retryAfterMs("not a date", now: now) == nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(retryAfterMs(formatter.string(from: now.addingTimeInterval(30)), now: now) == 30_000)
    }
}
