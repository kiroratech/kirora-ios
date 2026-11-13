import Foundation
import Testing
@testable import Kirora

@Suite("Sign-in and user tokens")
struct IdentityTests {
    @Test func sendsWithTheThreeCredentials() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed", properties: ["order_id": "1042"])
        await kirora.flush()
        let batch = try #require(app.server.batches.first)
        #expect(batch.headers["Kirora-Client-Key"] == "kirora_pk_test")
        #expect(batch.headers["Kirora-SDK"] == "kirora-ios/\(sdkVersion)")
        #expect(batch.token == userToken("user-1"))
        #expect(batch.path == "/client/v1/events/batch")
    }

    @Test func nothingIsSentBeforeSignIn() async throws {
        let app = TestApp()
        let kirora = app.start()
        kirora.track("Product Viewed")
        await kirora.flush()
        await settle()
        #expect(app.server.requests.isEmpty)
        // …and the events go as whoever signs in next.
        try await kirora.identify(userToken("user-1"))
        #expect(await eventually { app.server.sentEventNames.contains("Product Viewed") })
    }

    @Test func identifyWithoutATokenAsksTheApp() async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: { userToken("user-1") })
        try await kirora.identify()
        kirora.track("Signed In")
        await kirora.flush()
        #expect(app.server.batches.first?.token == userToken("user-1"))
    }

    @Test func identifyWithoutAnyTokenThrows() async {
        let app = TestApp()
        let kirora = app.start()
        await #expect(throws: KiroraError.self) { try await kirora.identify() }
    }

    @Test func aFailingFetchUserTokenThrowsUserTokenError() async {
        struct Down: Error {}
        let app = TestApp()
        let kirora = app.start(fetchUserToken: { throw Down() })
        await #expect(throws: UserTokenError.self) { try await kirora.identify() }
    }

    @Test func aHungFetchUserTokenTimesOut() async {
        let app = TestApp()
        let kirora = app.start(
            fetchUserToken: {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return userToken("user-1")
            },
            tokenTimeout: 0.1
        )
        await #expect(throws: UserTokenError.self) { try await kirora.identify() }
    }

    @Test func a401AsksForAFreshTokenOnceAndRetries() async throws {
        let app = TestApp()
        let fresh = userToken("user-1", issuedAt: 1_700_000_100)
        let calls = Locked(0)
        let kirora = app.start(fetchUserToken: {
            calls.withLock { $0 += 1 }
            return fresh
        })
        app.server.answer { request in
            request.token == userToken("user-1") ? FakeAnswer.error(401, "UNAUTHORIZED") : nil
        }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        await kirora.flush()
        #expect(calls.current == 1)
        #expect(app.server.batches.map(\.token) == [userToken("user-1"), fresh])
        #expect(app.server.sentEventNames.contains("Order Completed"))
    }

    @Test func aFreshTokenForSomeoneElseIsDiscarded() async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: { userToken("user-2") })
        app.server.answer { _ in .error(401, "UNAUTHORIZED") }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        await kirora.flush()
        // Only ever sent as user-1, never with user-2's token.
        #expect(!app.server.batches.isEmpty)
        #expect(app.server.batches.allSatisfy { $0.token == userToken("user-1") })
    }

    @Test func theLatestIdentifyWins() async throws {
        let app = TestApp()
        let asked = Locked(false)
        let kirora = app.start(fetchUserToken: {
            asked.withLock { $0 = true }
            try await Task.sleep(nanoseconds: 200_000_000)
            return userToken("slow")
        })
        let slow = Task { try await kirora.identify() }
        #expect(await eventually { asked.current })
        try await kirora.identify(userToken("fast"))
        try await slow.value
        kirora.track("After")
        await kirora.flush()
        #expect(app.server.batches.allSatisfy { $0.token == userToken("fast") })
    }

    @Test func readsTheSubjectOfAToken() {
        #expect(subjectOf(userToken("customer-881")) == "customer-881")
        #expect(subjectOf(userToken(nil)) == nil)
        #expect(subjectOf("not a token") == nil)
    }
}

@Suite("Logout")
struct LogoutTests {
    @Test func sendsWhatWaitsThenForgetsTheUser() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        await kirora.logout()
        #expect(app.server.sentEventNames.contains("Order Completed"))
        kirora.track("Signed Out Browse")
        await kirora.flush()
        await settle()
        #expect(!app.server.sentEventNames.contains("Signed Out Browse"))
    }

    @Test func unsentEventsAreNeverSentAsTheNextUser() async throws {
        let app = TestApp()
        let kirora = app.start()
        app.server.answer { _ in .networkError }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Private")
        await kirora.logout()
        app.server.answer { _ in nil }
        try await kirora.identify(userToken("user-2"))
        await kirora.flush()
        let sentAsUser2 = app.server.batches.filter { $0.token == userToken("user-2") }.flatMap(\.eventNames)
        #expect(!sentAsUser2.contains("Private"))
    }

    @Test func isSafeToCallTwice() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        await kirora.logout()
        await kirora.logout()
    }
}
