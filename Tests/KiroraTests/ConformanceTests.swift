import Foundation
import Testing
@testable import Kirora

// The shared conformance cases of the client SDK interface (`sdk-interface.md`, "Shared
// conformance cases"), and the 14 and 16 November additions they cover.

private func appOpens(_ app: TestApp) -> [SentRequest] {
    app.server.requests.filter { $0.path.hasSuffix("/app-opens") }
}

private func deletes(_ app: TestApp) -> Int {
    app.server.requests.filter { $0.method == "DELETE" }.count
}

/// A batch answer giving every event `code` as its error.
private func refusingEvents(_ code: String) -> @Sendable (SentRequest) -> FakeAnswer? {
    { request in
        guard request.path == "/client/v1/events/batch" else { return nil }
        let results = request.events.map { event -> JSONValue in
            .object([
                "idempotencyKey": event["idempotencyKey"] ?? .null,
                "error": .object(["code": .string(code), "message": .string("no")]),
            ])
        }
        return .ok(.object(["results": .array(results)]))
    }
}

@Suite("Ownership across sign-ins")
struct OwnershipTests {
    @Test func anEventAdoptedByANeverGoesAsB() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        kirora.track("Before sign-in")
        app.server.answer { $0.path == "/client/v1/events/batch" ? .networkError : nil }
        try await kirora.identify(userToken("A"))
        await kirora.flush()
        app.server.answer { _ in nil }
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        #expect(!app.server.batches.contains { subjectOf($0.token ?? "") == "B" && $0.eventNames.contains("Before sign-in") })
        // A, signing in again, sends it.
        try await kirora.identify(userToken("A"))
        await kirora.flush()
        #expect(app.server.batches.contains { subjectOf($0.token ?? "") == "A" && $0.eventNames == ["Before sign-in"] })
    }

    @Test func aSignInKiroraNeverAcceptedGivesBackWhatItAdopted() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        kirora.track("Before sign-in")
        app.server.answer { subjectOf($0.token ?? "") == "A" ? FakeAnswer(status: 401, body: nil) : nil }
        try await kirora.identify(userToken("A"))
        await kirora.flush()
        app.server.answer { _ in nil }
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        #expect(app.server.batches.contains { subjectOf($0.token ?? "") == "B" && $0.eventNames == ["Before sign-in"] })
    }

    @Test func whatIsTrackedWhileLoggingOutWaitsForTheNextUser() async throws {
        let app = TestApp()
        app.logoutWait = 0.3
        let kirora = app.start(push: .enabled, trackSessions: false)
        try await kirora.identify(userToken("A"))
        // A slow detachment keeps the logout under way; only logout sends one.
        app.server.answer { $0.method == "DELETE" ? FakeAnswer(status: 204, body: nil, delay: 0.25) : nil }
        let logout = Task { await kirora.logout() }
        #expect(await eventually { deletes(app) == 1 })
        kirora.track("During logout")
        await logout.value
        app.server.answer { _ in nil }
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        #expect(app.server.batches.contains { subjectOf($0.token ?? "") == "B" && $0.eventNames == ["During logout"] })
        #expect(!app.server.batches.contains { subjectOf($0.token ?? "") == "A" && $0.eventNames.contains("During logout") })
    }

    @Test func aNewUserBeginsANewVisit() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("X")
        await kirora.logout()
        try await kirora.identify(userToken("B"))
        kirora.track("Y")
        await kirora.flush()
        let sessions = app.server.batches.flatMap(\.events).compactMap { $0["context"]?["sessionId"]?.stringValue }
        #expect(app.server.sentEventNames.filter { $0 == "Session Started" }.count == 2)
        #expect(Set(sessions).count == 2)
    }

    @Test func aDirectSwitchToAnotherUserBeginsANewVisit() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("X")
        try await kirora.identify(userToken("B"))
        kirora.track("Y")
        await kirora.flush()
        #expect(app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.eventNames) == ["Session Started", "Y"])
    }
}

@Suite("Acknowledgements")
struct AcknowledgementTests {
    @Test func aRefusalThatMayPassLaterIsRetried() async throws {
        for code in ["RATE_LIMITED", "INTERNAL_ERROR", "SERVICE_UNAVAILABLE"] {
            let app = TestApp()
            let first = Locked(true)
            let refuse = refusingEvents(code)
            app.server.answer { request in first.withLock { f in defer { f = false }; return f } ? refuse(request) : nil }
            let kirora = app.start(trackSessions: false)
            try await kirora.identify(userToken("u"))
            kirora.track("A")
            await kirora.flush()
            #expect(await eventually { app.server.batches.count == 2 }, "\(code)")
            let keys = app.server.batches.map { $0.events.first?["idempotencyKey"] }
            #expect(keys[0] == keys[1], "the same key on a retry")
        }
    }

    @Test func aRefusalForGoodIsDroppedWithoutBlockingTheRest() async throws {
        let app = TestApp()
        app.server.answer(refusingEvents("PLAN_LIMIT_REACHED"))
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("A")
        await kirora.flush()
        app.server.answer { _ in nil }
        kirora.track("B")
        await kirora.flush()
        #expect(app.server.sentEventNames == ["A", "B"])
    }

    @Test func aRepeatedOrUnknownResultAcknowledgesNothing() async throws {
        let app = TestApp()
        let first = Locked(true)
        app.server.answer { request in
            guard request.path == "/client/v1/events/batch", first.withLock({ f in defer { f = false }; return f }) else { return nil }
            let key = request.events[0]["idempotencyKey"] ?? .null
            return .ok(.object(["results": .array([
                .object(["idempotencyKey": key]), .object(["idempotencyKey": key]),
                .object(["idempotencyKey": .string("someone-elses")]),
            ])]))
        }
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("A")
        await kirora.flush()
        #expect(await eventually { app.server.batches.count == 2 })
    }
}

@Suite("JSON snapshot and storage budgets")
struct SnapshotTests {
    @Test func anEventHoldingWhatJSONCantDropsAloneWithoutBlockingOthers() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("NaN", properties: ["x": Double.nan])
        kirora.track("Object", properties: ["x": NSObject()])
        kirora.track("Fine", properties: ["absent": Optional<String>.none as Any, "null": NSNull()])
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Fine"])
        #expect(app.server.batches.first?.events.first?["properties"] == .object(["null": .null]))
    }

    @Test func propertiesAreCopiedAtCapture() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        let list = NSMutableArray(array: ["a"])
        kirora.track("Copied", properties: ["list": list])
        list.add("b")
        await kirora.flush()
        #expect(app.server.batches.first?.events.first?["properties"] == .object(["list": .array([.string("a")])]))
    }

    @Test func theQueueKeepsAtMostAMillionBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-bytes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = EventQueue(file: PersistentFile(url: directory.appendingPathComponent("events.json"), onError: { _ in }))
        let big = String(repeating: "x", count: 100_000)
        func event(_ name: String, _ text: String) -> QueuedEvent {
            QueuedEvent(idempotencyKey: newId(), name: name, properties: ["text": .string(text)], occurredAt: "", context: [:])
        }
        for index in 0..<15 { queue.add(event("E\(index)", big), owner: "u") }
        let kept = queue.oldest(100, owner: "u")
        #expect(kept.count < 10)
        #expect(kept.last?.name == "E14")
        let bytes = kept.reduce(0) { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) }
        #expect(bytes <= maxQueuedBytes)
        // One event larger than the whole budget is dropped itself.
        queue.add(event("Huge", String(repeating: "x", count: maxQueuedBytes)), owner: "u")
        #expect(queue.oldest(100, owner: "u").map(\.name) == kept.map(\.name))
    }
}

@Suite("beforeSend")
struct BeforeSendTests {
    @Test func redactsEveryEventBeforeItIsStored() async throws {
        let app = TestApp()
        let seen = Locked<[String]>([])
        let kirora = app.start(beforeSend: { event in
            seen.withLock { $0.append(event.name) }
            var event = event
            event.properties["email"] = nil
            event.context["locale"] = nil
            return event
        })
        try await kirora.identify(userToken("u"))
        kirora.track("Signed Up", properties: ["email": "a@b.c", "plan": "pro"])
        await kirora.flush()
        #expect(seen.current == ["Session Started", "Signed Up"])
        let event = try #require(app.server.batches.flatMap(\.events).first { $0["name"] == .string("Signed Up") })
        #expect(event["properties"] == .object(["plan": .string("pro")]))
        #expect(event["context"]?["locale"] == nil)
        #expect(event["context"]?["device"]?["id"] != nil)
    }

    @Test func aRetrySendsTheRedactedEventWithoutCallingItAgain() async throws {
        let app = TestApp()
        let calls = Locked(0)
        app.server.answer { $0.path == "/client/v1/events/batch" && $0.events.count > 0 && calls.current == 1 ? .networkError : nil }
        let kirora = app.start(trackSessions: false, beforeSend: { event in
            calls.withLock { $0 += 1 }
            var event = event
            event.properties = ["redacted": true]
            return event
        })
        try await kirora.identify(userToken("u"))
        kirora.track("A", properties: ["secret": "s"])
        await kirora.flush()
        calls.withLock { $0 = 2 }
        await kirora.flush()
        #expect(app.server.batches.count >= 2)
        #expect(app.server.batches.allSatisfy { $0.events.first?["properties"] == .object(["redacted": .bool(true)]) })
    }

    @Test func nilAThrowOrNonJSONAnswerDropsTheEvent() async throws {
        struct Failure: Error {}
        let app = TestApp()
        let kirora = app.start(trackSessions: false, beforeSend: { event in
            switch event.name {
            case "Dropped": return nil
            case "Threw": throw Failure()
            case "Bad": var event = event; event.properties["x"] = NSObject(); return event
            default: return event
            }
        })
        try await kirora.identify(userToken("u"))
        for name in ["Dropped", "Threw", "Bad", "Kept"] { kirora.track(name) }
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Kept"])
    }

    @Test func trackingFromInsideItIsRefused() async throws {
        let app = TestApp()
        let client = Locked<Kirora?>(nil)
        let kirora = app.start(trackSessions: false, beforeSend: { event in
            client.current?.track("Recursive")
            return event
        })
        client.withLock { $0 = kirora }
        try await kirora.identify(userToken("u"))
        kirora.track("Outer")
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Outer"])
        client.withLock { $0 = nil }
    }

    @Test func isNeverCalledWithoutTrackingConsent() async throws {
        let app = TestApp()
        let calls = Locked(0)
        let kirora = app.start(requireTrackingConsent: true, beforeSend: { event in
            calls.withLock { $0 += 1 }
            return event
        })
        kirora.track("A")
        app.lifecycle.fire(.foreground)
        #expect(calls.current == 0)
    }
}

@Suite("Consent, storage and workspaces")
struct ConsentStorageTests {
    @Test func appOpensWaitForTrackingConsent() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled, requireTrackingConsent: true)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("u"))
        await settle()
        #expect(appOpens(app).isEmpty)
        #expect(app.stored(StorageKeys.appOpenActivity) == nil)
        kirora.setTrackingConsent(true)
        app.clock.advance(31 * 60)
        app.lifecycle.fire(.foreground)
        #expect(await eventually { appOpens(app).count == 1 })
    }

    @Test func withdrawingConsentDropsWaitingAppOpens() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path.hasSuffix("/app-opens") ? .networkError : nil }
        app.lifecycle.fire(.launched)
        #expect(await eventually { appOpens(app).count == 1 })
        kirora.setTrackingConsent(false)
        app.server.answer { _ in nil }
        await kirora.flush()
        await settle(0.4)
        #expect(appOpens(app).count == 1)
        #expect(app.store.keys.allSatisfy { !$0.hasPrefix("app-open") })
        // Operational push carries on: the device stays registered.
        #expect(app.stored(StorageKeys.deviceId) != nil)
    }

    @Test func unreadableConsentStorageWaitsForAFreshAnswerWhenConsentIsRequired() async throws {
        let app = TestApp()
        // As the store marks a state file it couldn't read.
        app.store.set("1", for: StorageKeys.stateUnreadable)
        let kirora = app.start(requireTrackingConsent: true)
        try await kirora.identify(userToken("u"))
        kirora.track("Before the answer")
        kirora.setTrackingConsent(true)
        kirora.track("After the answer")
        await kirora.flush()
        #expect(app.server.sentEventNames.contains("After the answer"))
        #expect(!app.server.sentEventNames.contains("Before the answer"))
    }

    @Test func unreadableConsentStorageTracksAsAFreshInstallUnlessARefusalIsOnRecord() async throws {
        let app = TestApp()
        app.store.set("1", for: StorageKeys.stateUnreadable)
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("No refusal on record")
        await kirora.flush()
        #expect(app.server.sentEventNames == ["No refusal on record"])

        // The main copy lost; the refusal kept in the second one holds.
        let refused = TestApp()
        refused.store.set("1", for: StorageKeys.stateUnreadable)
        refused.refusals.set("refused", for: refused.scopedKey(StorageKeys.trackingConsent))
        let other = refused.start(trackSessions: false)
        try await other.identify(userToken("u"))
        other.track("Refused")
        await other.flush()
        #expect(refused.server.sentEventNames.isEmpty)
    }

    @Test func neitherCopyReadableTracksNothing() async throws {
        let app = TestApp()
        app.store.set("1", for: StorageKeys.stateUnreadable)
        app.refusals.set("1", for: StorageKeys.stateUnreadable)
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("Unknown")
        kirora.setTrackingConsent(true)
        kirora.track("Granted")
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Granted"])
    }

    @Test func aRefusalIsKeptInBothCopiesAndAGrantClearsBoth() {
        let app = TestApp()
        let kirora = app.start()
        kirora.setTrackingConsent(false)
        #expect(app.stored(StorageKeys.trackingConsent) == "refused")
        #expect(app.refusals.string(app.scopedKey(StorageKeys.trackingConsent)) == "refused")
        // Losing the main copy doesn't lose the refusal.
        app.store.set(nil, for: app.scopedKey(StorageKeys.trackingConsent))
        kirora.track("X")
        #expect(app.server.requests.isEmpty)
        kirora.setTrackingConsent(true)
        #expect(app.stored(StorageKeys.trackingConsent) == "granted")
        #expect(app.refusals.string(app.scopedKey(StorageKeys.trackingConsent)) == nil)
    }

    @Test func eachWorkspaceKeepsItsOwnDeviceIdAndChoices() async throws {
        let app = TestApp()
        app.start(clientKey: "kirora_pk_one").track("X")
        app.start(clientKey: "kirora_pk_two").setTrackingConsent(false)
        let one = app.stored(StorageKeys.deviceId, clientKey: "kirora_pk_one")
        #expect(one != nil)
        #expect(app.stored(StorageKeys.trackingConsent, clientKey: "kirora_pk_one") == nil)
        #expect(app.stored(StorageKeys.trackingConsent, clientKey: "kirora_pk_two") == "refused")
        app.start(clientKey: "kirora_pk_two").track("Y")
        #expect(app.stored(StorageKeys.deviceId, clientKey: "kirora_pk_two") == nil)
    }
}

@Suite("Device cleanup")
struct CleanupTests {
    @Test func anotherUsersFailedRegistrationKeepsTheCleanupGoing() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        app.server.answer { $0.method == "DELETE" || $0.method == "PUT" ? .networkError : nil }
        await kirora.logout()
        try? await kirora.identify(userToken("B"))
        let before = deletes(app)
        #expect(await eventually { deletes(app) > before })
        // Still as A, never with B's token.
        #expect(app.server.requests.filter { $0.method == "DELETE" }.allSatisfy { subjectOf($0.token ?? "") == "A" })
    }

    @Test func anotherUserSigningInWithoutPermissionKeepsTheCleanupGoing() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        app.server.answer { $0.method == "DELETE" ? .networkError : nil }
        await kirora.logout()
        app.push.status.withLock { $0 = .notDetermined }
        try await kirora.identify(userToken("B"))
        let before = deletes(app)
        #expect(await eventually { deletes(app) > before })
    }

    @Test func aLateDetachAfterTheUserSignsInAgainIsKeptBy409() async throws {
        let app = TestApp()
        let server = DeviceServer()
        let online = Locked(false)
        app.server.answer { request in
            if request.method == "DELETE", !online.current { return .networkError }
            return server.answer(request)
        }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        let firstLastSeenAt = try #require(app.server.requests.first { $0.method == "DELETE" }?.query["lastSeenAt"])
        // A signs in again: registered again, never skipped as fresh.
        try await kirora.identify(userToken("A"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 2)
        online.withLock { $0 = true }
        // The late detachment names the earlier registration: Kirora keeps the new one.
        #expect(await eventually { server.conflicts.current == 1 })
        #expect(app.server.requests.filter { $0.method == "DELETE" }.allSatisfy { $0.query["lastSeenAt"] == firstLastSeenAt })
        let after = deletes(app)
        await settle(0.4)
        #expect(deletes(app) == after)
        #expect(await kirora.getPushStatus() == .enabled)
    }

    @Test func everyDetachNamesTheLastRegistration() async throws {
        let app = TestApp()
        let server = DeviceServer()
        app.server.answer { server.answer($0) }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.setPushEnabled(false)
        try await kirora.identify(userToken("B"))
        await kirora.setPushEnabled(true)
        await kirora.logout()
        let sent = app.server.requests.filter { $0.method == "DELETE" }.map { $0.query["lastSeenAt"] }
        #expect(sent == [server.lastSeenAt(1), server.lastSeenAt(2)])
    }

    @Test func aDeviceNeverRegisteredDetachesUnconditionally() async throws {
        let app = TestApp()
        // A registration Kirora answered without a `lastSeenAt`.
        app.store.set(
            #"{"userSubject":"A","config":"","token":"abcd01","targetKind":"apns_token","pushAppId":"\#(FakeKirora.pushAppId)","permission":"granted","at":0,"installationId":"device-1","detaching":false,"deviceSecret":"secret"}"#,
            for: StorageKeys.pushRegistration("kirora_pk_test@api.test.kirora.io")
        )
        let kirora = app.start(push: .enabled)
        app.push.status.withLock { $0 = .notDetermined }
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        let delete = try #require(app.server.requests.first { $0.method == "DELETE" })
        #expect(delete.query["lastSeenAt"] == nil)
    }

    @Test func aDetachRefusedForGoodKeepsTheDeviceId() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        kirora.setTrackingConsent(false)
        app.server.answer { $0.method == "DELETE" ? .error(403, "FORBIDDEN") : nil }
        await kirora.logout()
        await settle(0.3)
        // Kirora may still have the device, so the id that names it is kept.
        #expect(app.stored(StorageKeys.deviceId) != nil)
        #expect(deletes(app) == 1)
    }

    @Test func aConfirmedDetachLetsTheRefusedDeviceIdGo() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        kirora.setTrackingConsent(false)
        await kirora.logout()
        #expect(app.stored(StorageKeys.deviceId) == nil)
    }

    @Test func aDetachWaitsForARegistrationStillUnderWay() async throws {
        let app = TestApp()
        app.logoutWait = 0.3
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        // A background refresh, slow to land, as logout starts.
        app.clock.advance(25 * 60 * 60)
        app.server.answer { $0.method == "PUT" ? FakeAnswer(status: 200, body: .object(["data": .object(["lastSeenAt": .string("2026-11-16T09:00:00.000Z")])]), delay: 0.15) : nil }
        app.lifecycle.fire(.foreground)
        #expect(await eventually { app.server.requests.filter { $0.method == "PUT" }.count == 2 })
        await kirora.logout()
        #expect(await eventually { deletes(app) == 1 })
        #expect(app.server.requests.first { $0.method == "DELETE" }?.query["lastSeenAt"] == "2026-11-16T09:00:00.000Z")
    }
}

/// Kirora's device registrations, as far as the detach precondition needs: each `PUT` gets a
/// later `lastSeenAt`, and a `DELETE` naming an earlier one than the user's latest is 409.
final class DeviceServer: @unchecked Sendable {
    private let state = Locked<(count: Int, latest: [String: Int])>((0, [:]))
    let conflicts = Locked(0)

    func lastSeenAt(_ registration: Int) -> String {
        "2026-11-16T10:00:\(String(format: "%02d", registration)).000Z"
    }

    func answer(_ request: SentRequest) -> FakeAnswer? {
        guard request.path.hasPrefix("/client/v1/devices/"), !request.path.hasSuffix("/app-opens") else { return nil }
        let user = subjectOf(request.token ?? "") ?? ""
        switch request.method {
        case "PUT":
            let number = state.withLock { state -> Int in
                state.count += 1
                state.latest[user] = state.count
                return state.count
            }
            return FakeAnswer(status: 200, body: .object(["data": .object(["lastSeenAt": .string(lastSeenAt(number))])]))
        case "DELETE":
            let latest = state.withLock { $0.latest[user] }
            if let named = request.query["lastSeenAt"], let latest, named < lastSeenAt(latest) {
                conflicts.withLock { $0 += 1 }
                return .error(409, "CONFLICT")
            }
            state.withLock { _ = $0.latest.removeValue(forKey: user) }
            return .noContent
        default:
            return nil
        }
    }
}

@Suite("Push on and off")
struct PushStatusTests {
    @Test func statusFollowsPermissionThenRegistration() async throws {
        let app = TestApp()
        #expect(await app.start().getPushStatus() == .unsupported)
        app.push.status.withLock { $0 = .notDetermined }
        let kirora = app.start(push: .enabled)
        #expect(await kirora.getPushStatus() == .unanswered)
        app.push.status.withLock { $0 = .denied }
        #expect(await kirora.getPushStatus() == .denied)
        app.push.status.withLock { $0 = .authorized }
        #expect(await kirora.getPushStatus() == .disabled)
        try await kirora.identify(userToken("u"))
        #expect(await kirora.getPushStatus() == .enabled)
        await kirora.logout()
        #expect(await kirora.getPushStatus() == .disabled)
    }

    @Test func aFailedRegistrationIsDisabled() async throws {
        let app = TestApp()
        app.server.answer { $0.method == "PUT" ? .networkError : nil }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("u"))
        #expect(await kirora.getPushStatus() == .disabled)
    }

    @Test func turningPushOffDetachesAndHoldsForTheNextUser() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.setPushEnabled(false)
        #expect(deletes(app) == 1)
        #expect(await kirora.getPushStatus() == .disabled)
        await kirora.logout()
        try await kirora.identify(userToken("B"))
        // Restarted too: the choice is the device's.
        try await app.start(push: .enabled).identify(userToken("B"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 1)
    }

    @Test func turningPushOnRegistersWithoutPrompting() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("u"))
        await kirora.setPushEnabled(false)
        await kirora.setPushEnabled(true)
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 2)
        #expect(await kirora.getPushStatus() == .enabled)
        // Without permission it never prompts.
        await kirora.setPushEnabled(false)
        app.push.status.withLock { $0 = .notDetermined }
        app.push.promptAnswer.withLock { $0 = .denied }
        await kirora.setPushEnabled(true)
        #expect(app.push.status.current == .notDetermined)
    }

    @Test func grantingThePromptTurnsPushBackOn() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("u"))
        await kirora.setPushEnabled(false)
        #expect(await kirora.requestPushPermission() == .granted)
        #expect(await kirora.getPushStatus() == .enabled)
    }
}

@Suite("Notification buttons")
struct ButtonTests {
    @Test func aTappedButtonOpensItsLinkAndCountsAsAClick() async {
        let server = FakeKirora()
        let opened = Locked<[URL]>([])
        let handler = PushTapHandler(transport: server, apiBase: { testApiBase }, openURL: { url in opened.withLock { $0.append(url) } })
        let payload = KiroraPushPayload(userInfo: [
            "kirora": "true", "trackingUrl": "https://api.test.kirora.io/t/p/abc", "actionUrl": "myapp://home",
            "buttons": #"[{"title":"Track order","url":"myapp://orders/1"},{"title":"Later"}]"#,
        ])!
        await handler.handle(payload, action: .button("0"))
        await handler.handle(payload, action: .button("Later"))
        #expect(opened.current == [URL(string: "myapp://orders/1")!])
        #expect(server.requests.map(\.body) == [
            .object(["event": .string("clicked")]), .object(["event": .string("opened")]),
        ])
    }

    /// The app's own action on a Kirora push (its category won over Kirora's buttons) isn't
    /// a tap on the push: not reported as an open.
    @Test func theAppsOwnActionIsNotReported() async throws {
        let server = FakeKirora()
        let handler = PushTapHandler(transport: server, apiBase: { testApiBase }, openURL: { _ in })
        let payload = KiroraPushPayload(userInfo: ["kirora": "true", "trackingUrl": "https://api.test.kirora.io/t/p/abc"])!
        let heard = Locked(false)
        await handler.handle(payload, action: .button("REPLY"), tapped: { _ in heard.withLock { $0 = true } })
        #expect(server.requests.isEmpty)
        // A wrapper's listener still hears it.
        #expect(heard.current)
    }
}

@Suite("Cancellation and shared files")
struct CancellationTests {
    /// A spaced file writes at most once a second; what's held back is written before any
    /// read of the file, by any instance, and by a wait for writes.
    @Test func aSpacedFileHoldsWritesBackUntilReadOrWaitedFor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("events.json")
        let file = PersistentFile(url: url, writeSpacing: 1, onError: { _ in })
        file.write { Data("1".utf8) }
        file.waitForWrites()
        file.write { Data("2".utf8) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try Data(contentsOf: url) == Data("1".utf8))
        // Another instance's read sees it, as a restarted client would.
        let other = PersistentFile(url: url, onError: { _ in })
        #expect(other.readNow { $0 } == Data("2".utf8))
        file.write { Data("3".utf8) }
        other.waitForWrites()
        #expect(try Data(contentsOf: url) == Data("3".utf8))
    }

    @Test func withdrawingConsentCancelsASendUnderWay() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" ? FakeAnswer(status: 200, body: nil, delay: 1) : nil }
        kirora.track("A")
        let flushing = Task { await kirora.flush() }
        #expect(await eventually { app.server.batches.count == 1 })
        kirora.setTrackingConsent(false)
        await flushing.value
        await settle(1.2)
        #expect(app.server.completedRequests.filter { $0.path == "/client/v1/events/batch" }.isEmpty)
        #expect(app.server.batches.count == 1)
    }

    @Test func twoClientsOfAWorkspaceShareOneQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let one = EventQueue.shared(file: PersistentFile(url: url, onError: { _ in }), log: Log(level: .none))
        let two = EventQueue.shared(file: PersistentFile(url: url, onError: { _ in }), log: Log(level: .none))
        #expect(one === two)
        func event(_ name: String) -> QueuedEvent {
            QueuedEvent(idempotencyKey: newId(), name: name, properties: [:], occurredAt: "", context: [:])
        }
        one.add(event("From one"), owner: nil)
        two.add(event("From two"), owner: nil)
        // Adopted once, whichever client's sign-in comes first.
        #expect(one.adopt("A").count == 2)
        #expect(two.adopt("B").isEmpty)
        #expect(two.oldest(10, owner: "A").map(\.name) == ["From one", "From two"])
    }

    @Test func twoWorkspacesShareOneStateFileWithoutOverwritingEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let base = FileKeyValueStore.shared(file: PersistentFile(url: url, onError: { _ in }))
        let one = WorkspaceStore(base: FileKeyValueStore.shared(file: PersistentFile(url: url, onError: { _ in })), namespace: "one")
        let two = WorkspaceStore(base: FileKeyValueStore.shared(file: PersistentFile(url: url, onError: { _ in })), namespace: "two")
        one.set("id-one", for: StorageKeys.deviceId)
        two.set("id-two", for: StorageKeys.deviceId)
        PersistentFile(url: url, onError: { _ in }).waitForWrites()
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        #expect(saved[StorageKeys.scoped(StorageKeys.deviceId, "one")] == "id-one")
        #expect(saved[StorageKeys.scoped(StorageKeys.deviceId, "two")] == "id-two")
        _ = base
    }
}

@Suite("Storage that fails")
struct FailingStorageTests {
    @Test func eventsGoOnInMemoryWhenTheyCantBeSaved() async throws {
        // A file where its directory should be: every write fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-blocked-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let file = PersistentFile(url: blocker.appendingPathComponent("events.json"), onError: { _ in })
        let queue = EventQueue(file: file)
        func event(_ name: String) -> QueuedEvent {
            QueuedEvent(idempotencyKey: newId(), name: name, properties: [:], occurredAt: "", context: [:])
        }
        queue.add(event("First"), owner: "u")
        file.waitForWrites()
        #expect(file.writeFailed)
        queue.add(event("Second"), owner: "u")
        #expect(queue.oldest(10, owner: "u").map(\.name) == ["First", "Second"])
    }

    @Test func aRefusalThatCantBeSavedWinsOverTheStaleGrantWithoutDeletingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let stateFile = PersistentFile(url: directory.appendingPathComponent("state.json"), onError: { _ in })
        let consentFile = PersistentFile(url: directory.appendingPathComponent("consent.json"), onError: { _ in })
        let consent = TrackingConsent(
            store: FileKeyValueStore(file: stateFile), refusals: FileKeyValueStore(file: consentFile), required: false
        )
        _ = consent.answer(true)
        stateFile.waitForWrites()
        // Storage stops taking writes: the refusal stays in memory only.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        _ = consent.answer(false)
        stateFile.waitForWrites()
        consentFile.waitForWrites()
        #expect(stateFile.writeFailed)
        #expect(consent.allowed == false)
        #expect(consent.refused)
        // The stale grant is ignored, never deleted: reading changed nothing on disk.
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: stateFile.url))
        #expect(saved[StorageKeys.trackingConsent] == "granted")
    }
}

@Suite("Review fixes")
struct ReviewFixTests {
    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kirora-review-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    @Test func aCorruptStateFileNeverTurnsALostRefusalIntoTheDefault() throws {
        let url = tempFile("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let first = WorkspaceStore(base: FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in })), namespace: "ws")
        #expect(TrackingConsent(store: first, refusals: MemoryKeyValueStore(), required: true).allowed == false)
        // Another value saved rewrites the file...
        first.set("id", for: StorageKeys.deviceId)
        PersistentFile(url: url, onError: { _ in }).waitForWrites()
        // ...and the next launch still waits for a fresh answer.
        let next = WorkspaceStore(base: FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in })), namespace: "ws")
        let consent = TrackingConsent(store: next, refusals: MemoryKeyValueStore(), required: true)
        #expect(consent.allowed == false)
        _ = consent.answer(true)
        #expect(consent.allowed)
    }

    @Test func aStateFileThatCantBeReadIsNeverWrittenOver() throws {
        let url = tempFile("state.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = Data(#"{"tracking-consent:ws":"refused"}"#.utf8)
        try saved.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let store = WorkspaceStore(base: FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in })), namespace: "ws")
        // Its refusal copy locked too, as before the first unlock: nothing is tracked.
        let refusals = MemoryKeyValueStore()
        refusals.set("1", for: StorageKeys.stateUnreadable)
        #expect(TrackingConsent(store: store, refusals: refusals, required: false).allowed == false)
        store.set("id", for: StorageKeys.deviceId)
        PersistentFile(url: url, onError: { _ in }).waitForWrites()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == saved)
    }

    /// A file locked at launch (before the first unlock) that can be read later: what it
    /// holds comes back and is merged with what changed meanwhile, then saved.
    @Test func aStateFileReadableLaterIsMergedNotLost() async throws {
        let url = tempFile("state.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"device-id:ws":"saved-id","tracking-consent:ws":"granted"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let file = PersistentFile(url: url, onError: { _ in })
        let store = WorkspaceStore(base: FileKeyValueStore(file: file), namespace: "ws")
        let consent = TrackingConsent(store: store, refusals: MemoryKeyValueStore(), required: true)
        #expect(!consent.allowed)
        #expect(!store.isReadable())
        // Meanwhile: a device id made, and the user's own answer.
        store.set("made-meanwhile", for: StorageKeys.deviceId)
        _ = consent.answer(false)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(store.isReadable())
        // The saved device id is kept; the answer given meanwhile wins over the saved one.
        #expect(store.string(StorageKeys.deviceId) == "saved-id")
        #expect(store.string(StorageKeys.trackingConsent) == "refused")
        #expect(!consent.allowed)
        file.waitForWrites()
        let written = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        #expect(written["device-id:ws"] == "saved-id")
        #expect(written["tracking-consent:ws"] == "refused")
        #expect(written[StorageKeys.stateUnreadable] == nil)
    }

    @Test func aLockedStateFileStopsBlockingTrackingOnceReadable() async throws {
        let url = tempFile("state.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"device-id:ws":"saved-id"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let store = WorkspaceStore(base: FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in })), namespace: "ws")
        // Its refusal copy locked too, as before the first unlock.
        let refusals = MemoryKeyValueStore()
        refusals.set("1", for: StorageKeys.stateUnreadable)
        let consent = TrackingConsent(store: store, refusals: refusals, required: false)
        #expect(!consent.allowed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        // Any later read tries the file again, in the background.
        #expect(await eventually(5) { consent.allowed })
    }

    @Test func pushRegistrationWaitsUntilStorageCanBeRead() async throws {
        let app = TestApp()
        app.store.unreadableNow.withLock { $0 = true }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("u"))
        #expect(app.server.requests.filter { $0.method == "PUT" && $0.path.contains("/devices/") }.isEmpty)
        app.store.unreadableNow.withLock { $0 = false }
        try await kirora.identify(userToken("u"))
        #expect(app.server.requests.filter { $0.method == "PUT" && $0.path.contains("/devices/") }.count == 1)
    }

    @Test func eventsSavedInALockedFileAreKeptWithThoseTrackedMeanwhile() async throws {
        let url = tempFile("events.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = EventQueue(file: PersistentFile(url: url, onError: { _ in }))
        saved.add(queuedEvent("Saved 1"), owner: nil)
        saved.add(queuedEvent("Saved 2"), owner: nil)
        PersistentFile(url: url, onError: { _ in }).waitForWrites()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let file = PersistentFile(url: url, onError: { _ in })
        let queue = EventQueue(file: file)
        queue.add(queuedEvent("Meanwhile"), owner: nil)
        #expect(queue.count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        file.retryNowIfUnreadable()
        #expect(queue.count == 3)
        #expect(queue.oldest(10, owner: nil).isEmpty)
        file.waitForWrites()
        let reread = EventQueue(file: PersistentFile(url: url, onError: { _ in }))
        #expect(reread.count == 3)
    }

    @Test func clientsOfAWorkspaceAgreeOnConsent() async throws {
        let app = TestApp()
        let one = app.start()
        let two = app.start()
        two.setTrackingConsent(true)
        one.setTrackingConsent(false)
        try await two.identify(userToken("u"))
        two.track("After the refusal")
        await two.flush()
        #expect(app.server.sentEventNames.isEmpty)
        _ = one
    }

    @Test func whatIsTrackedDuringLogoutStartsAVisitOfItsOwn() async throws {
        let app = TestApp()
        app.logoutWait = 0.3
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        let aSession = try #require(app.server.batches.flatMap(\.events).first?["context"]?["sessionId"])
        app.server.answer { $0.method == "DELETE" ? FakeAnswer(status: 204, body: nil, delay: 0.2) : nil }
        let logout = Task { await kirora.logout() }
        #expect(await eventually { deletes(app) == 1 })
        kirora.track("During logout")
        await logout.value
        app.server.answer { _ in nil }
        try await kirora.identify(userToken("B"))
        kirora.track("B's")
        await kirora.flush()
        let bEvents = app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.events)
        #expect(bEvents.allSatisfy { $0["context"]?["sessionId"] != aSession })
        // The visit begun during logout becomes B's: one visit, not two.
        #expect(Set(bEvents.compactMap { $0["context"]?["sessionId"]?.stringValue }).count == 1)
    }

    @Test func aLateCancelFromAnEarlierRefusalLeavesTheGrantsSendAlone() async throws {
        let server = FakeKirora()
        server.answer { $0.path == "/client/v1/events/batch" ? FakeAnswer(status: 503, body: nil, delay: 0.2) : nil }
        let identity = Identity(fetchUserToken: nil)
        try await identity.signIn(token: userToken("u")) {}
        let api = ClientAPI(clientKey: "kirora_pk_test", apiUrl: "https://api.test.kirora.io", identity: identity, transport: server)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = EventQueue(file: PersistentFile(url: directory.appendingPathComponent("events.json"), onError: { _ in }))
        queue.add(QueuedEvent(idempotencyKey: newId(), name: "Granted", properties: [:], occurredAt: "", context: [:]), owner: "u")
        let delivery = EventDelivery(
            api: api, identity: identity, queue: queue, consentAllowed: { true },
            log: Log(level: .none), timing: DeliveryTiming(), now: { Date() }
        )
        let sending = Task { await delivery.flush() }
        #expect(await eventually { server.batches.count == 1 })
        // The refusal's cancel arrives after the grant: consent is allowed again.
        await delivery.cancelIfDisallowed()
        await sending.value
        #expect(server.completedRequests.count == 1)
    }

    @Test func aBeforeSendWaitingOnAnotherTrackingThreadDoesNotFreeze() async throws {
        let app = TestApp()
        let otherTracked = DispatchSemaphore(value: 0)
        let client = Locked<Kirora?>(nil)
        let kirora = app.start(trackSessions: false, beforeSend: { event in
            guard event.name == "First" else { return event }
            // The hook waits for another thread that tracks meanwhile.
            DispatchQueue.global().async {
                client.current?.track("Second")
                otherTracked.signal()
            }
            _ = otherTracked.wait(timeout: .now() + 2)
            return event
        })
        client.withLock { $0 = kirora }
        try await kirora.identify(userToken("u"))
        let started = Date()
        kirora.track("First")
        // Frozen, it would wait out the hook's 2 seconds; a busy machine may take over 1.
        #expect(Date().timeIntervalSince(started) < 1.5)
        await kirora.flush()
        #expect(Set(app.server.sentEventNames) == ["First", "Second"])
        client.withLock { $0 = nil }
    }
}

@Suite("getState")
struct StateTests {
    @Test func aNewClientHasNothingYet() {
        let app = TestApp()
        let kirora = app.start(push: .enabled, trackSessions: false)
        let state = kirora.getState()
        #expect(state.isInitialized)
        #expect(!state.isIdentified)
        #expect(state.sessionId == nil)
        #expect(state.pushToken == nil)
        #expect(state.trackingConsent)
        #expect(!state.pushConsent)
        #expect(state.queuedEventCount == 0)
        // Reading it makes nothing: no device id, no request.
        #expect(state.deviceId == nil)
        #expect(kirora.getState().deviceId == nil)
        #expect(app.server.requests.isEmpty)
    }

    @Test func itFollowsTheClient() async throws {
        let app = TestApp()
        app.server.answer { request in
            request.method == "POST" && request.path.hasSuffix("/events/batch") ? FakeAnswer.error(503, "SERVICE_UNAVAILABLE") : nil
        }
        let kirora = app.start(push: .enabled)
        kirora.track("Waiting")
        try await kirora.identify(userToken("u"))
        try await kirora.setPushConsent(true)
        let state = kirora.getState()
        #expect(state.isIdentified)
        #expect(state.deviceId != nil)
        #expect(state.deviceId == app.stored(StorageKeys.deviceId))
        #expect(state.sessionId != nil)
        #expect(state.pushToken == "abcd01")
        #expect(state.pushConsent)
        #expect(state.queuedEventCount >= 1)

        try await kirora.setPushConsent(false)
        #expect(!kirora.getState().pushConsent)
        kirora.setTrackingConsent(false)
        #expect(!kirora.getState().trackingConsent)
        await kirora.logout()
        #expect(!kirora.getState().isIdentified)
        #expect(kirora.getState().pushToken == nil)
        kirora.destroy()
        #expect(!kirora.getState().isInitialized)
    }

    @Test func pushConsentIsTheSignedInUsers() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("a"))
        try await kirora.setPushConsent(true)
        #expect(kirora.getState().pushConsent)
        // Another user signing in doesn't inherit it, and it's gone from the device.
        try await kirora.identify(userToken("b"))
        #expect(!kirora.getState().pushConsent)
        #expect(app.stored(StorageKeys.pushConsent) == nil)
        try await kirora.setPushConsent(true)
        await kirora.logout()
        #expect(!kirora.getState().pushConsent)
        #expect(app.stored(StorageKeys.pushConsent) == nil)
        // Signing back in doesn't bring it back: it's recorded again when the app asks again.
        try await kirora.identify(userToken("b"))
        #expect(!kirora.getState().pushConsent)
    }

    @Test func aRefusedPushConsentLeavesTheLastRecordedChoice() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("u"))
        try await kirora.setPushConsent(true)
        app.server.answer { $0.path.hasSuffix("/push-consent") ? FakeAnswer.error(500, "INTERNAL_ERROR") : nil }
        await #expect(throws: KiroraApiError.self) { try await kirora.setPushConsent(false) }
        #expect(kirora.getState().pushConsent)
    }
}

@Suite("Errors reach the app")
struct ErrorTests {
    @Test func everyErrorIsAKiroraError() {
        let errors: [Error] = [
            KiroraApiError(status: 500, code: "INTERNAL_ERROR", message: "Kirora answered 500"),
            UserTokenError(URLError(.timedOut)),
            KiroraError("set fetchUserToken"),
        ]
        #expect(errors.allSatisfy { $0 is KiroraError })
        #expect(asKiroraError(URLError(.notConnectedToInternet)) is KiroraError)
        #expect((asKiroraError(URLError(.notConnectedToInternet)) as? KiroraError)?.underlying is URLError)
        #expect(asKiroraError(CancellationError()) is CancellationError)
    }

    @Test func aPushConsentNotRecordedThrows() async throws {
        let app = TestApp()
        let kirora = app.start()
        // Nobody signed in: nothing recorded.
        await #expect(throws: KiroraError.self) { try await kirora.setPushConsent(true) }
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path.hasSuffix("/push-consent") ? .networkError : nil }
        do {
            try await kirora.setPushConsent(true)
            Issue.record("expected a throw")
        } catch let error as KiroraApiError {
            Issue.record("a network failure isn't Kirora's answer: \(error)")
        } catch let error as KiroraError {
            #expect(error.underlying != nil)
        }
        app.server.answer { $0.path.hasSuffix("/push-consent") ? FakeAnswer.error(503, "SERVICE_UNAVAILABLE") : nil }
        await #expect(throws: KiroraApiError.self) { try await kirora.setPushConsent(true) }
        #expect(!kirora.getState().pushConsent)
    }

    @Test func identifyThrowsForASetupError() async {
        let app = TestApp()
        let kirora = app.start()
        await #expect(throws: KiroraError.self) { try await kirora.identify() }
        let other = TestApp()
        let badUrl = other.start(apiUrl: "not an address")
        await #expect(throws: KiroraError.self) { try await badUrl.identify(userToken("u")) }
    }
}

func queuedEvent(_ name: String) -> QueuedEvent {
    QueuedEvent(idempotencyKey: newId(), name: name, properties: [:], occurredAt: "", context: [:])
}

@Suite("Events built while beforeSend runs")
struct BeforeSendWindowTests {
    /// A beforeSend that waits at the gate while `holding` is set.
    final class HeldBeforeSend: @unchecked Sendable {
        let holding = Locked(false)
        /// Opened once an event reached the hook and waits there.
        let entered = Gate()
        let open = DispatchSemaphore(value: 0)
        func pass(_ event: BeforeSendEvent) -> BeforeSendEvent? {
            if holding.current {
                entered.open()
                // On the GCD thread `track` runs on, never a test's.
                open.wait()
            }
            return event
        }

        /// Tracks `name` on another thread, holding it in beforeSend while `meanwhile` runs,
        /// then lets it go and waits for `track` to return. Waits are bounded and never
        /// block a Swift concurrency thread.
        func track(_ kirora: Kirora, _ name: String, meanwhile: () async throws -> Void) async throws {
            holding.withLock { $0 = true }
            let returned = Gate()
            DispatchQueue.global().async {
                kirora.track(name)
                returned.open()
            }
            await entered.wait(upTo: 5)
            holding.withLock { $0 = false }
            try await meanwhile()
            open.signal()
            await returned.wait(upTo: 5)
        }
    }

    @Test func anEventOfAUserWhoSignedOutMeanwhileIsForgotten() async throws {
        let app = TestApp()
        let hook = HeldBeforeSend()
        let kirora = app.start(trackSessions: false, beforeSend: { hook.pass($0) })
        try await kirora.identify(userToken("A"))
        try await hook.track(kirora, "While signing out") { await kirora.logout() }
        // A signs in again: nothing of theirs from before the logout is left to send.
        try await kirora.identify(userToken("A"))
        await kirora.flush()
        #expect(!app.server.sentEventNames.contains("While signing out"))
    }

    @Test func anEventFromBeforeSignInIsAdoptedByWhoeverSignedInMeanwhile() async throws {
        let app = TestApp()
        let hook = HeldBeforeSend()
        let kirora = app.start(trackSessions: false, beforeSend: { hook.pass($0) })
        try await hook.track(kirora, "Before sign-in") { try await kirora.identify(userToken("A")) }
        await kirora.flush()
        let sent = app.server.batches.filter { $0.eventNames.contains("Before sign-in") }
        #expect(sent.count == 1)
        #expect(sent.first.map { subjectOf($0.token ?? "") } == "A")
    }

    @Test func anEventBuiltBeforeConsentWasWithdrawnAndGivenAgainIsForgotten() async throws {
        let app = TestApp()
        let hook = HeldBeforeSend()
        let kirora = app.start(trackSessions: false, beforeSend: { hook.pass($0) })
        try await kirora.identify(userToken("A"))
        try await hook.track(kirora, "Before the refusal") {
            kirora.setTrackingConsent(false)
            kirora.setTrackingConsent(true)
        }
        await kirora.flush()
        #expect(!app.server.sentEventNames.contains("Before the refusal"))
    }
}

@Suite("Code review fixes")
struct CodeReviewFixTests {
    @Test func anEventWithoutANameIsRefusedHere() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("")
        kirora.track("Named")
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Named"])
    }
}

@Suite("Second code review fixes")
struct SecondReviewTests {
    private func lockedFile(_ name: String, holding contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kirora-review2-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    private func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    @Test func eventsClearedWhileTheirFileWasLockedStayCleared() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kirora-review2-\(UUID().uuidString)").appendingPathComponent("events.json")
        defer { unlock(url); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = EventQueue(file: PersistentFile(url: url, onError: { _ in }))
        saved.add(queuedEvent("X's"), owner: "X")
        saved.add(queuedEvent("Y's"), owner: "Y")
        PersistentFile(url: url, onError: { _ in }).waitForWrites()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let file = PersistentFile(url: url, onError: { _ in })
        let queue = EventQueue(file: file)
        // X logs out while the file is locked.
        queue.clearOwned { owner, _ in owner == "X" }
        unlock(url)
        file.retryNowIfUnreadable()
        #expect(queue.oldest(10, owner: "X").isEmpty)
        #expect(queue.oldest(10, owner: "Y").map(\.name) == ["Y's"])

        // Consent withdrawn while locked: nothing comes back.
        let again = PersistentFile(url: url, onError: { _ in })
        file.waitForWrites()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let other = EventQueue(file: again)
        other.clearAll()
        unlock(url)
        again.retryNowIfUnreadable()
        #expect(other.count == 0)
    }

    @Test func aValueRemovedWhileTheFileWasLockedStaysRemoved() throws {
        let url = try lockedFile("state.json", holding: Data(#"{"device-id:ws":"saved-id"}"#.utf8))
        defer { unlock(url); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceStore(base: FileKeyValueStore(file: PersistentFile(url: url, onError: { _ in })), namespace: "ws")
        // A refusal forgets the device id meanwhile.
        store.set("made", for: StorageKeys.deviceId)
        store.set(nil, for: StorageKeys.deviceId)
        unlock(url)
        _ = store.isReadable()
        #expect(store.string(StorageKeys.deviceId) == nil)
    }

    @Test func aLogoutDuringARetriedDetachDoesNotStartASecondOne() async throws {
        let app = TestApp()
        app.server.answer { $0.method == "DELETE" ? .networkError : nil }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.setPushEnabled(false)
        #expect(kirora.push.pendingDetachments == 1)
        await kirora.logout()
        #expect(kirora.push.pendingDetachments == 1)
    }
}

@Suite("Docs review fixes")
struct DocsReviewTests {
    /// IOS-01: a result that's neither Kirora's accepted shape nor its refused one proves
    /// nothing, so the event stays, unchanged, for a retry.
    @Test(arguments: [
        JSONValue.object([:]),                                                      // the key alone
        .object(["error": .string("unreadable")]),                                  // a scalar error
        .object(["error": .object([:])]),                                           // an error without a code
        .object(["error": .object(["code": .string("")])]),                         // an empty code
        .object(["event": .string("x")]),                                           // a scalar event
        .object(["event": recordedEvent, "error": .object(["code": .string("X")])]), // both at once
    ])
    func anUnreadableResultKeepsTheEvent(_ shape: JSONValue) async throws {
        let app = TestApp()
        let first = Locked(true)
        app.server.answer { request in
            guard request.path == "/client/v1/events/batch", first.withLock({ f in defer { f = false }; return f }) else { return nil }
            guard case .object(var fields) = shape else { return nil }
            fields["idempotencyKey"] = request.events[0]["idempotencyKey"] ?? .null
            return .ok(.object(["results": .array([.object(fields)])]))
        }
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("Kept", properties: ["n": 1])
        await kirora.flush()
        // Kept and sent again (after the backoff), the same event and key, until a proper
        // answer settles it.
        #expect(await eventually { app.server.batches.count == 2 })
        let sent = app.server.batches.flatMap(\.events)
        #expect(sent.count == 2)
        #expect(sent.first?["idempotencyKey"] == sent.last?["idempotencyKey"])
        #expect(sent.first?["properties"] == sent.last?["properties"])
        #expect(kirora.getState().queuedEventCount == 0)
    }
}

@Suite("Docs review fixes: getState push token")
struct PushTokenStateTests {
    @Test func aRestartBeforeSignInShowsNoToken() async throws {
        let app = TestApp()
        let first = app.start(push: .enabled)
        try await first.identify(userToken("A"))
        #expect(first.getState().pushToken == "abcd01")
        let restarted = app.start(push: .enabled)
        #expect(restarted.getState().pushToken == nil)
        try await restarted.identify(userToken("A"))
        #expect(restarted.getState().pushToken == "abcd01")
    }

    @Test func aSwitchWhoseRegistrationFailedShowsNoToken() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        app.server.answer { $0.method == "PUT" && $0.path.contains("/devices/") ? FakeAnswer.error(503, "SERVICE_UNAVAILABLE") : nil }
        try await kirora.identify(userToken("B"))
        #expect(kirora.getState().pushToken == nil)
        #expect(await kirora.getPushStatus() == .disabled)
    }

    /// IOS-03: the detachment uses the outgoing user's token as captured, without asking the
    /// app for a fresh one; a 401 leaves the device secret, and a 401 to that ends it.
    @Test func aDetachNeverRefreshesTheToken() async throws {
        let app = TestApp()
        let fetches = Locked(0)
        app.server.answer { $0.method == "DELETE" ? FakeAnswer.error(401, "UNAUTHORIZED") : nil }
        let kirora = app.start(fetchUserToken: {
            fetches.withLock { $0 += 1 }
            return userToken("A", issuedAt: 1_800_000_000)
        }, push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        await settle(0.3)
        #expect(fetches.current == 0)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.map { $0.headers["Authorization"] ?? "" }
            == ["Bearer \(userToken("A"))", "Device \(app.server.requests.first { $0.method == "PUT" }?.deviceSecret ?? "")"])
    }

    @Test func pushTurnedOffShowsNoToken() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.setPushEnabled(false)
        #expect(kirora.getState().pushToken == nil)
    }
}

/// IOS-05: UIKit sends `.launched` on the main thread while the client starts. Handling it
/// may wait for the state file's first read, so it happens off that thread.
@Suite("Docs review fixes: launch")
struct LaunchIOTests {
    /// Sends `.launched` as UIKit's source does in the foreground: from inside `start`,
    /// handled on its own serial queue.
    final class LaunchingLifecycle: AppLifecycleSource, @unchecked Sendable {
        let queue = DispatchQueue(label: "test.lifecycle")
        func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) { queue.async { handler(.launched) } }
        func stop() {}
        func runInBackground(_ name: String, _ work: @escaping @Sendable () async -> Void) { Task { await work() } }
    }

    @Test func aSlowStateFileNeverHoldsUpTheAppAtLaunch() async throws {
        let app = TestApp()
        let url = app.directory.appendingPathComponent("slow-state.json")
        // The file's queue busy for 300ms before its first read.
        let file = PersistentFile(url: url, onError: { _ in })
        file.readSoon { _ in Thread.sleep(forTimeInterval: 0.3) }
        let environment = KiroraEnvironment(
            transport: app.server, store: FileKeyValueStore(file: file), refusals: MemoryKeyValueStore(),
            eventsFile: { _ in PersistentFile(url: app.directory.appendingPathComponent("slow-events.json"), onError: { _ in }) },
            lifecycle: LaunchingLifecycle(), pushPlatform: app.push, tokens: app.tokens, deviceInfo: app.deviceInfo,
            timing: app.timing, tokenTimeout: 30, now: { Date() }, installPushIntegration: { _ in }
        )
        let started = Date()
        let kirora = Kirora(
            options: KiroraOptions(clientKey: "kirora_pk_test", logLevel: .none, apiUrl: "https://api.test.kirora.io"),
            environment: environment
        )
        #expect(Date().timeIntervalSince(started) < 0.15)
        // The launch is still handled, once the file is read: its visit begins.
        #expect(await eventually { kirora.getState().sessionId != nil })
        kirora.destroy()
    }
}

@Suite("Docs review fixes: app-open spacing")
struct AppOpenSpacingTests {
    /// IOS-06: with visits off, the spacing between app opens is kept in memory only.
    @Test func withVisitsOffTheSpacingIsntSaved() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled, trackSessions: false)
        try await kirora.identify(userToken("A"))
        app.lifecycle.fire(.launched)
        app.lifecycle.fire(.foreground)
        #expect(await eventually { app.server.requests.contains { $0.path.hasSuffix("/app-opens") } })
        await settle()
        // Spaced all the same: the return to the foreground right after sent nothing.
        #expect(app.server.requests.filter { $0.path.hasSuffix("/app-opens") }.count == 1)
        #expect(app.stored(StorageKeys.appOpenActivity) == nil)
    }

    @Test func withVisitsOnTheSpacingIsSavedWithThem() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        app.lifecycle.fire(.launched)
        #expect(app.stored(StorageKeys.appOpenActivity) != nil)
    }
}

@Suite("Event context")
struct EventContextTests {
    /// Kirora accepts these, in Segment's names, and refuses any other with 400: no
    /// network, and on iOS no device model, nor any hardware or advertising id.
    @Test func carriesTheAcceptedFieldsOnly() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("u"))
        kirora.track("Viewed")
        await kirora.flush()
        let event = try #require(app.server.batches.flatMap(\.events).first { $0["name"] == .string("Viewed") })
        let context = try #require(event["context"])
        guard case .object(let fields) = context else { Issue.record("no context"); return }
        #expect(Set(fields.keys) == ["app", "os", "screen", "device", "sessionId", "locale", "timezone"])
        #expect(context["app"] == .object([
            "name": .string("Shop"), "version": .string("2.4.0"), "build": .string("412"), "namespace": .string("com.example.shop"),
        ]))
        #expect(context["os"] == .object(["name": .string("iOS"), "version": .string("17.4.1")]))
        #expect(context["screen"]?["width"] == .int(393))
        #expect(context["screen"]?["height"] == .int(852))
        // 3.0 goes as the JSON number 3.
        #expect(context["screen"]?["density"] == .int(3))
        #expect(context["device"]?["manufacturer"] == .string("Apple"))
        #expect(context["device"]?["type"] == .string("ios"))
        #expect(context["device"]?["id"] == app.stored(StorageKeys.deviceId).map { .string($0) })
        guard case .object(let device)? = context["device"] else { return }
        #expect(Set(device.keys) == ["id", "manufacturer", "type"])
    }

    @Test func leavesOutWhatTheDeviceCantRead() async throws {
        let app = TestApp()
        app.deviceInfo.screen = { nil }
        app.deviceInfo.appName = { nil }
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("u"))
        kirora.track("Viewed")
        await kirora.flush()
        let context = try #require(app.server.batches.flatMap(\.events).first?["context"])
        #expect(context["screen"] == nil)
        #expect(context["sessionId"] == nil)
        #expect(context["app"]?["name"] == nil)
    }
}

@Suite("onAuthenticationFailed")
struct AuthenticationFailedTests {
    /// Starts a client whose failures land in `reasons`.
    private func start(
        _ app: TestApp, fetch: (@Sendable () async throws -> String?)?, push: KiroraPushOptions? = nil,
        reasons: Locked<[AuthenticationFailureReason]>
    ) -> Kirora {
        app.start(
            fetchUserToken: fetch, onAuthenticationFailed: { reason in reasons.withLock { $0.append(reason) } },
            push: push, trackSessions: false
        )
    }

    @Test func aTokenThatCantBeFetchedWhileSendingIsFetchFailed() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: { throw TokenServerDown() }, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" ? .error(401, "UNAUTHORIZED") : nil }
        kirora.track("Viewed")
        await kirora.flush()
        #expect(await eventually { !reasons.current.isEmpty })
        // Retries that fail again don't tell the app again.
        await settle(0.5)
        #expect(app.server.batches.count > 1)
        #expect(reasons.current == [.fetchFailed])
    }

    @Test func noTokenFromFetchUserTokenWhileSendingIsFetchFailed() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: { nil }, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" ? .error(401, "UNAUTHORIZED") : nil }
        kirora.track("Viewed")
        await kirora.flush()
        #expect(await eventually { !reasons.current.isEmpty })
        #expect(reasons.current == [.fetchFailed])
        #expect(app.server.batches.allSatisfy { $0.token != "" })
    }

    @Test func aFreshTokenKiroraRefusesWhileSendingIsRefused() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: { userToken("u", issuedAt: 1_799_999_100) }, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" ? .error(401, "UNAUTHORIZED") : nil }
        kirora.track("Viewed")
        await kirora.flush()
        #expect(await eventually { !reasons.current.isEmpty })
        await settle()
        #expect(reasons.current == [.refused])
        // The fresh token was tried.
        #expect(app.server.batches.contains { $0.token == userToken("u", issuedAt: 1_799_999_100) })
    }

    @Test func aRefusedTokenWithNoFetchUserTokenIsRefused() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: nil, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" ? .error(401, "UNAUTHORIZED") : nil }
        kirora.track("Viewed")
        await kirora.flush()
        #expect(await eventually { reasons.current == [.refused] })
    }

    @Test func tellsAgainOnlyAfterASuccessOrANewIdentify() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let refusing = Locked(true)
        let kirora = start(app, fetch: nil, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" && refusing.current ? .error(401, "UNAUTHORIZED") : nil }
        kirora.track("One")
        await kirora.flush()
        kirora.track("Two")
        await kirora.flush()
        #expect(await eventually { reasons.current.count == 1 })
        await settle()
        #expect(reasons.current.count == 1)
        // A request that succeeds (after identify(), as nothing is sent until then with no
        // fetchUserToken): the next failure is told.
        refusing.withLock { $0 = false }
        try await kirora.identify(userToken("u"))
        kirora.track("Three")
        await kirora.flush()
        #expect(await eventually { app.server.sentEventNames.contains("Three") })
        refusing.withLock { $0 = true }
        kirora.track("Four")
        await kirora.flush()
        #expect(await eventually { reasons.current.count == 2 })
        // A new identify(): told again.
        try await kirora.identify(userToken("u"))
        kirora.track("Five")
        await kirora.flush()
        #expect(await eventually { reasons.current.count == 3 })
    }

    @Test func notForAFailureIdentifyThrows() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: { throw TokenServerDown() }, push: .enabled, reasons: reasons)
        app.server.answer { $0.path == "/client/v1/push-app" ? .error(401, "UNAUTHORIZED") : nil }
        await #expect(throws: UserTokenError.self) { try await kirora.identify(userToken("u")) }
        await settle()
        #expect(reasons.current.isEmpty)
    }

    /// The events identify() sends may be refused for the same token its push registration
    /// is: identify() throws it, so the app isn't told twice.
    @Test func notForTheSameFailureWhileIdentifyThrowsIt() async throws {
        for _ in 0..<5 {
            let app = TestApp()
            let reasons = Locked<[AuthenticationFailureReason]>([])
            // Notifications allowed only later, so the second sign-in registers.
            app.push.status.withLock { $0 = .notDetermined }
            let kirora = start(app, fetch: nil, push: .enabled, reasons: reasons)
            try await kirora.identify(userToken("u"))
            await kirora.flush()
            // The user's own event, waiting; then their token is revoked.
            app.server.answer { _ in .networkError }
            kirora.track("Waiting")
            await kirora.flush()
            let before = app.server.batches.count
            app.push.status.withLock { $0 = .authorized }
            app.server.answer { request in
                switch request.path {
                case "/client/v1/events/batch": return .error(401, "UNAUTHORIZED")
                // Refused after the events, so their failure comes first.
                case "/client/v1/push-app":
                    var refused = FakeAnswer.error(401, "UNAUTHORIZED")
                    refused.delay = 0.2
                    return refused
                default: return nil
                }
            }
            await #expect(throws: KiroraApiError.self) { try await kirora.identify(userToken("u", issuedAt: 1_799_999_100)) }
            #expect(await eventually { app.server.batches.count > before })
            await settle()
            #expect(reasons.current.isEmpty)
        }
    }

    @Test func notForAFailureSetPushConsentThrows() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: { userToken("u", issuedAt: 1_799_999_100) }, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/push-consent" ? .error(401, "UNAUTHORIZED") : nil }
        await #expect(throws: KiroraApiError.self) { try await kirora.setPushConsent(true) }
        await settle()
        #expect(reasons.current.isEmpty)
    }

    @Test func notForAUserWhoHasSignedOut() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = start(app, fetch: { throw TokenServerDown() }, reasons: reasons)
        try await kirora.identify(userToken("u"))
        app.server.answer { $0.path == "/client/v1/events/batch" ? .error(401, "UNAUTHORIZED") : nil }
        kirora.track("Viewed")
        await kirora.logout()
        await settle()
        #expect(reasons.current.isEmpty)
    }
}
