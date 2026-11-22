import Foundation
import Testing
@testable import Kirora

@Suite("Events and delivery")
struct DeliveryTests {
    @Test func identifyingTheSameUserAgainMidSendSendsEachEventOnce() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        let firstBatch = Locked(true)
        app.server.answer { request in
            guard request.path == "/client/v1/events/batch", firstBatch.withLock({ first in defer { first = false }; return first }) else { return nil }
            var answer = FakeKirora.defaultAnswer(request)
            answer.delay = 0.3
            return answer
        }
        try await kirora.identify(userToken("user-1"))
        kirora.track("One")
        let held = Task { await kirora.flush() }
        #expect(await eventually { app.server.batches.count == 1 })
        try await kirora.identify(userToken("user-1", issuedAt: 1_799_999_100))
        kirora.track("Two")
        await kirora.flush()
        await held.value
        #expect(app.server.batches.count == 2)
        #expect(app.server.sentEventNames == ["One", "Two"])
    }

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
        #expect(context["device"]?["id"]?.stringValue == app.stored(StorageKeys.deviceId))
        #expect(context["locale"] == .string("en-GB"))
        #expect(context["timezone"] == .string("Africa/Lagos"))
        #expect(context["sessionId"]?.stringValue != nil)
        // Only the fields Kirora's context takes.
        if case .object(let fields) = context {
            #expect(Set(fields.keys).isSubset(of: ["app", "os", "screen", "device", "sessionId", "locale", "timezone"]))
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
                    : .object(["idempotencyKey": event["idempotencyKey"]!, "replayed": .bool(false), "event": recordedEvent])
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
        let kirora = app.start(trackSessions: false)
        let failures = Locked(1)
        app.server.answer { request in
            guard request.path.hasSuffix("/events/batch") else { return nil }
            return failures.withLock { left in
                defer { left -= 1 }
                return left > 0 ? FakeAnswer.error(503, "UNAVAILABLE") : nil
            }
        }
        // Waiting before sign-in, so it's in the first batch, alone.
        kirora.track("Order Completed")
        try await kirora.identify(userToken("user-1"))
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
        // Dropped at the first refusal: never sent again.
        #expect(app.server.sentEventNames.filter { $0 == "Order Completed" }.count == 1)
        #expect(kirora.getState().queuedEventCount == 0)
    }

    /// A 400 or 422 naming an event: halving the batch finds it.
    @Test(arguments: [400, 422])
    func anInvalidBatchIsSplitToFindTheBadEvent(status: Int) async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        app.server.answer { request in
            guard request.path.hasSuffix("/events/batch") else { return nil }
            guard let bad = request.eventNames.firstIndex(of: "Bad") else { return nil }
            return .validationError(fields: ["events.\(bad).name"], status: status)
        }
        for name in ["A", "B", "Bad", "C"] { kirora.track(name) }
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(await eventually {
            Set(app.server.batches.filter { !$0.eventNames.contains("Bad") }.flatMap(\.eventNames)) == ["A", "B", "C"]
        })
    }

    /// A refusal every event meets is paced: one event dropped, then a backoff, not a burst
    /// of requests that empties the queue.
    @Test func aRefusalEveryEventMeetsDoesntEmptyTheQueue() async throws {
        let app = TestApp()
        app.timing = DeliveryTiming(flushAtEvents: 20, flushInterval: 5, maxRetryDelay: 5)
        let kirora = app.start(trackSessions: false)
        app.server.answer { request in
            request.path.hasSuffix("/events/batch") ? .validationError(fields: ["events.0.context.x"], status: 422) : nil
        }
        for index in 0..<200 { kirora.track("Event \(index)") }
        // Signing in starts one pass.
        try await kirora.identify(userToken("user-1"))
        await settle(0.3)
        // One event isolated in 8 requests, then one more full batch refused: then the wait.
        #expect(app.server.batches.count <= 10)
        #expect(kirora.getState().queuedEventCount == 199)
    }

    /// A whole request refused for something no event caused: from a wrong `apiUrl`, a proxy
    /// or captive portal, or a `Kirora-SDK` header Kirora won't take. Dropping would empty the
    /// queue, so the events wait and go once the request is accepted.
    @Test func aWholeRequestRefusalKeepsTheEvents() async throws {
        let refusals: [FakeAnswer] = [
            .error(403, "FORBIDDEN"), .error(404, "NOT_FOUND"), .error(409, "CONFLICT"),
            FakeAnswer(status: 302, body: nil, headers: ["Location": "https://portal.example"]),
            FakeAnswer(status: 404, body: nil),
            .validationError(fields: ["kirora-sdk"], in: "headers"),
            // A proxy's own 400: not Kirora's error body.
            FakeAnswer(status: 400, body: nil),
            // Kirora's, but no event at fault.
            .error(400, "BAD_REQUEST"),
            .error(400, "VALIDATION_ERROR"),
            // A 422 naming no event (a proxy answering 422 to everything) is the same.
            FakeAnswer(status: 422, body: nil),
            .error(422, "VALIDATION_ERROR"),
            .validationError(fields: ["kirora-sdk"], in: "headers", status: 422),
        ]
        for refusal in refusals {
            let app = TestApp()
            let kirora = app.start(trackSessions: false)
            let refusing = Locked(true)
            app.server.answer { request in
                request.path.hasSuffix("/events/batch") && refusing.current ? refusal : nil
            }
            for name in ["A", "B", "C"] { kirora.track(name) }
            try await kirora.identify(userToken("user-1"))
            await kirora.flush()
            // Never split: each event alone would be refused the same.
            #expect(app.server.batches.allSatisfy { $0.events.count == 3 }, "\(refusal.status)")
            #expect(kirora.getState().queuedEventCount == 3, "\(refusal.status)")
            refusing.withLock { $0 = false }
            #expect(await eventually { kirora.getState().queuedEventCount == 0 }, "\(refusal.status)")
            #expect(Set(app.server.sentEventNames) == ["A", "B", "C"])
        }
    }

    /// A whole-request refusal backs off like a server error: it isn't retried at once.
    @Test func aWholeRequestRefusalBacksOff() async throws {
        let app = TestApp()
        app.timing = DeliveryTiming(flushAtEvents: 20, flushInterval: 0.3, maxRetryDelay: 5)
        let kirora = app.start(trackSessions: false)
        app.server.answer { $0.path.hasSuffix("/events/batch") ? .error(404, "NOT_FOUND") : nil }
        try await kirora.identify(userToken("user-1"))
        for index in 0..<5 { kirora.track("Event \(index)") }
        await settle(0.5)
        #expect(app.server.batches.count <= 2)
    }

    @Test func a401WithNoFetchUserTokenWaitsForIdentify() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        let refusing = Locked(true)
        app.server.answer { $0.path.hasSuffix("/events/batch") && refusing.current ? .error(401, "UNAUTHORIZED") : nil }
        try await kirora.identify(userToken("user-1"))
        kirora.track("One")
        await kirora.flush()
        let tries = app.server.batches.count
        // Nothing goes as the refused token: not on a timer, a new event or a flush.
        for index in 0..<25 { kirora.track("More \(index)") }
        await kirora.flush()
        await settle(0.4)
        #expect(app.server.batches.count == tries)
        #expect(kirora.getState().queuedEventCount == 26)
        // A new token from identify() sends them.
        refusing.withLock { $0 = false }
        try await kirora.identify(userToken("user-1", issuedAt: 1_799_999_500))
        #expect(await eventually { kirora.getState().queuedEventCount == 0 })
    }

    @Test func a401ThatNoFreshTokenResolvesBacksOff() async throws {
        let app = TestApp()
        app.timing = DeliveryTiming(flushAtEvents: 20, flushInterval: 0.3, maxRetryDelay: 5)
        let fetches = Locked(0)
        let kirora = app.start(
            fetchUserToken: { fetches.withLock { $0 += 1 }; return userToken("user-1", issuedAt: 1_799_999_100) },
            trackSessions: false
        )
        app.server.answer { $0.path.hasSuffix("/events/batch") ? .error(401, "UNAUTHORIZED") : nil }
        try await kirora.identify(userToken("user-1"))
        let fetchedAtSignIn = fetches.current
        for index in 0..<45 { kirora.track("Event \(index)") }
        await settle(0.5)
        // Not a refused request and a token fetch for every 20 events: one, then the backoff.
        #expect(app.server.batches.count <= 4)
        #expect(fetches.current - fetchedAtSignIn <= 2)
        #expect(kirora.getState().queuedEventCount == 45)
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
        PersistentFile(url: url, onError: { _ in }).waitForWrites()
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
    @Test func convertsWhatJSONCanHold() throws {
        let date = Date(timeIntervalSince1970: 0)
        let value = try JSONValue.fromObject([
            "string": "a", "int": 3, "double": 1.5, "bool": true, "null": NSNull(),
            "date": date, "url": URL(string: "https://kirora.io")!,
            "nested": ["list": [1, "two", Optional<Int>.none as Any]],
            "absent": Optional<String>.none as Any,
        ])
        #expect(value["string"] == .string("a"))
        #expect(value["int"] == .int(3))
        #expect(value["double"] == .double(1.5))
        #expect(value["bool"] == .bool(true))
        #expect(value["null"] == .null)
        #expect(value["date"] == .string("1970-01-01T00:00:00.000Z"))
        #expect(value["url"] == .string("https://kirora.io"))
        // In an array, nil is null; as a member, it's left out, as Swift's JSON encoder does.
        #expect(value["nested"] == .object(["list": .array([.int(1), .string("two"), .null])]))
        #expect(value.keys.contains("absent") == false)
    }

    @Test func refusesWhatJSONCantHoldFaithfully() {
        #expect(throws: JSONValue.Unrepresentable.self) { try JSONValue.fromObject(["nan": Double.nan]) }
        #expect(throws: JSONValue.Unrepresentable.self) { try JSONValue.fromObject(["inf": Double.infinity]) }
        #expect(throws: JSONValue.Unrepresentable.self) { try JSONValue.fromObject(["object": NSObject()]) }
        #expect(throws: JSONValue.Unrepresentable.self) { try JSONValue.fromObject(["keys": [1: "a"] as [AnyHashable: Any]]) }
        // An array that holds itself.
        let circular = NSMutableArray()
        circular.add(circular)
        #expect(throws: JSONValue.Unrepresentable.self) { try JSONValue.fromObject(["loop": circular]) }
    }

    @Test func tellsBooleansFromNumbers() throws {
        #expect(try JSONValue.from(NSNumber(value: true)) == .bool(true))
        #expect(try JSONValue.from(NSNumber(value: 1)) == .int(1))
        #expect(try JSONValue.from(NSNumber(value: 2.5)) == .double(2.5))
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
