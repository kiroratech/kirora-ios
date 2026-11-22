import Foundation
import Testing
@testable import Kirora

@Suite("Tracking consent, read alone")
struct TrackingConsentReadTests {
    @Test func answersAsGetStateDoes() {
        let app = TestApp()
        let kirora = app.start(requireTrackingConsent: true)
        #expect(!kirora.trackingConsent)
        #expect(kirora.trackingConsent == kirora.getState().trackingConsent)
        kirora.setTrackingConsent(true)
        #expect(kirora.trackingConsent)
        kirora.setTrackingConsent(false)
        #expect(!kirora.trackingConsent)
        #expect(kirora.trackingConsent == kirora.getState().trackingConsent)
    }
}

@Suite("Visits, lifecycle and consent")
struct SessionTests {
    @Test func aVisitBeginsWithSessionStartedWithoutProperties() async throws {
        let app = TestApp()
        let kirora = app.start()
        app.lifecycle.fire(.launched)
        kirora.track("Order Completed")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        let events = app.server.batches.flatMap(\.events)
        #expect(events.map { $0["name"]?.stringValue } == ["Session Started", "Order Completed"])
        #expect(events[0]["properties"] == .object([:]))
        #expect(events[0]["context"]?["sessionId"] == events[1]["context"]?["sessionId"])
    }

    @Test func aVisitEndsAfter30MinutesWithoutActivity() async throws {
        let app = TestApp()
        let kirora = app.start()
        kirora.track("First")
        app.clock.advance(29 * 60)
        kirora.track("Same Visit")
        app.clock.advance(31 * 60)
        kirora.track("New Visit")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Session Started", "First", "Same Visit", "Session Started", "New Visit"])
    }

    @Test func timeInTheForegroundNeverEndsAVisit() async throws {
        let app = TestApp()
        let kirora = app.start()
        app.lifecycle.fire(.launched)
        for _ in 0..<12 {
            app.clock.advance(5 * 60)
            app.lifecycle.fire(.keepAlive)
        }
        kirora.track("An Hour Later")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.sentEventNames.filter { $0 == "Session Started" }.count == 1)
    }

    @Test func sessionsCanBeTurnedOff() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        app.lifecycle.fire(.launched)
        kirora.track("Order Completed")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Order Completed"])
        #expect(app.server.batches.first?.events.first?["context"]?["sessionId"] == nil)
    }

    @Test func lifecycleEventsAreOffByDefault() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        app.lifecycle.fire(.launched)
        app.lifecycle.fire(.background)
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.sentEventNames.isEmpty)
    }

    @Test func tracksInstalledOpenedUpdatedAndBackgrounded() async throws {
        let app = TestApp()
        var kirora = app.start(trackSessions: false, trackAppLifecycle: true)
        app.lifecycle.fire(.launched)
        app.lifecycle.fire(.background)
        app.lifecycle.fire(.foreground)
        // A relaunch of the same version: no Installed or Updated.
        kirora = app.start(trackSessions: false, trackAppLifecycle: true)
        app.lifecycle.fire(.launched)
        app.deviceInfo.appVersion = { "2.5.0" }
        app.deviceInfo.appBuild = { "420" }
        kirora = app.start(trackSessions: false, trackAppLifecycle: true)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        let events = app.server.batches.flatMap(\.events)
        #expect(events.compactMap { $0["name"]?.stringValue } == [
            "Application Installed", "Application Opened", "Application Backgrounded", "Application Opened",
            "Application Opened",
            "Application Updated", "Application Opened",
        ])
        #expect(events[0]["properties"] == .object(["version": .string("2.4.0"), "build": .string("412")]))
        #expect(events[1]["properties"]?["from_background"] == .bool(false))
        #expect(events[3]["properties"]?["from_background"] == .bool(true))
        #expect(events[5]["properties"] == .object([
            "version": .string("2.5.0"), "build": .string("420"),
            "previous_version": .string("2.4.0"), "previous_build": .string("412"),
        ]))
    }

    @Test func goingToTheBackgroundSendsWhatWaits() async throws {
        let app = TestApp()
        app.timing.flushInterval = 60
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        await settle()
        kirora.track("Order Completed")
        app.lifecycle.fire(.background)
        #expect(await eventually { app.server.sentEventNames.contains("Order Completed") })
        #expect(app.lifecycle.backgroundWork.current == 1)
    }

    @Test func theDeviceIdIsARandomUUIDKeptOnTheDevice() async throws {
        let app = TestApp()
        let kirora = app.start()
        kirora.track("One")
        let id = try #require(app.stored(StorageKeys.deviceId))
        #expect(UUID(uuidString: id) != nil)
        app.start().track("Two")
        #expect(app.stored(StorageKeys.deviceId) == id)
    }
}

@Suite("Tracking consent")
struct ConsentTests {
    @Test func tracksAndStoresNothingBeforeConsent() async throws {
        let app = TestApp()
        let kirora = app.start(requireTrackingConsent: true)
        app.lifecycle.fire(.launched)
        kirora.track("Before Consent")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.batches.isEmpty)
        #expect(app.stored(StorageKeys.deviceId) == nil)
        #expect(app.stored(StorageKeys.session) == nil)

        kirora.setTrackingConsent(true)
        kirora.track("After Consent")
        await kirora.flush()
        #expect(app.server.sentEventNames == ["Session Started", "After Consent"])
    }

    @Test func storesNothingAtAllBeforeConsentWithPushOff() async throws {
        let app = TestApp()
        let kirora = app.start(requireTrackingConsent: true, trackAppLifecycle: true)
        app.lifecycle.fire(.launched)
        app.lifecycle.fire(.keepAlive)
        app.lifecycle.fire(.background)
        app.lifecycle.fire(.foreground)
        kirora.track("Before Consent")
        kirora.trackScreenView("Home")
        await settle()
        #expect(app.store.keys.isEmpty)
        // Withdrawing keeps only the answer itself.
        kirora.setTrackingConsent(false)
        #expect(app.store.keys == [app.scopedKey(StorageKeys.trackingConsent)])
    }

    @Test func consentIsRememberedOnTheDevice() async throws {
        let app = TestApp()
        app.start(requireTrackingConsent: true).setTrackingConsent(true)
        let kirora = app.start(requireTrackingConsent: true)
        kirora.track("Next Launch")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.sentEventNames.contains("Next Launch"))
    }

    @Test func withdrawalForgetsWhatWaits() async throws {
        let app = TestApp()
        let kirora = app.start()
        kirora.track("Waiting")
        kirora.setTrackingConsent(false)
        kirora.track("After Withdrawal")
        try await kirora.identify(userToken("user-1"))
        await kirora.flush()
        #expect(app.server.batches.isEmpty)
        #expect(app.stored(StorageKeys.deviceId) == nil)
    }

    /// After a relaunch, events from before sign-in continue the last visit, A's. If B signs
    /// in and adopts them, they leave A's visit: two users' visits are never joined.
    @Test func anotherUserAdoptingEventsFromBeforeSignInTakesThemOutOfTheLastUsersVisit() async throws {
        let app = TestApp()
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        let aSession = try #require(app.server.batches.flatMap(\.events).first?["context"]?["sessionId"]?.stringValue)

        // Relaunched: nobody is signed in yet, and A's visit is still live.
        kirora = app.start()
        kirora.track("Before sign-in")
        try await kirora.identify(userToken("B"))
        kirora.track("B's")
        await kirora.flush()
        let bEvents = app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.events)
        let before = try #require(bEvents.first { $0["name"]?.stringValue == "Before sign-in" })
        #expect(before["context"]?["sessionId"] == nil)
        #expect(bEvents.allSatisfy { $0["context"]?["sessionId"]?.stringValue != aSession })
    }

    /// The same user signing in again keeps them in their visit.
    @Test func theSameUserAdoptingEventsFromBeforeSignInKeepsTheirVisit() async throws {
        let app = TestApp()
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        let aSession = try #require(app.server.batches.flatMap(\.events).first?["context"]?["sessionId"]?.stringValue)

        kirora = app.start()
        kirora.track("Before sign-in")
        try await kirora.identify(userToken("A"))
        await kirora.flush()
        let before = try #require(app.server.batches.flatMap(\.events).first { $0["name"]?.stringValue == "Before sign-in" })
        #expect(before["context"]?["sessionId"]?.stringValue == aSession)
    }

    /// As with a `beforeSend`, whose events are queued once it returns: a sign-in meanwhile
    /// adopts them straight away, and the same rule applies.
    @Test func anEventHeldByBeforeSendLeavesTheLastUsersVisitToo() async throws {
        let app = TestApp()
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        let aSession = try #require(app.server.batches.flatMap(\.events).first?["context"]?["sessionId"]?.stringValue)

        let signedIn = DispatchSemaphore(value: 0)
        let inHook = Locked(false)
        let relaunched = app.start(beforeSend: { event in
            if event.name == "Before sign-in" {
                inHook.withLock { $0 = true }
                signedIn.wait()
            }
            return event
        })
        kirora = relaunched
        let tracking = Task.detached { relaunched.track("Before sign-in") }
        #expect(await eventually { inHook.current })
        try await kirora.identify(userToken("B"))
        signedIn.signal()
        await tracking.value
        await kirora.flush()
        let bEvents = app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.events)
        let before = try #require(bEvents.first { $0["name"]?.stringValue == "Before sign-in" })
        #expect(before["context"]?["sessionId"] == nil)
        #expect(bEvents.allSatisfy { $0["context"]?["sessionId"]?.stringValue != aSession })
    }
}
