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
        let app = TestApp()
        let kirora = app.start(fetchUserToken: { throw TokenServerDown() })
        await #expect(throws: UserTokenError.self) { try await kirora.identify() }
    }

    /// No token (nil or empty) is a failed fetch: nothing is sent with an empty token.
    @Test(arguments: [nil, ""] as [String?])
    func fetchUserTokenWithNoTokenThrowsUserTokenError(token: String?) async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: { token }, trackSessions: false)
        kirora.track("Viewed")
        let error = await #expect(throws: UserTokenError.self) { try await kirora.identify() }
        #expect(error?.message == "fetchUserToken returned no token")
        await kirora.flush()
        #expect(app.server.batches.allSatisfy { $0.token != "" })
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
        let fresh = userToken("user-1", issuedAt: 1_799_999_100)
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

    // MARK: Refreshing before expiry (spec, 20 November)

    @Test func aTokenIsRefreshed60SecondsBeforeItExpires() async throws {
        let app = TestApp()
        let fresh = userToken("user-1", issuedAt: 1_800_000_000, expiresIn: 7200)
        let calls = Locked(0)
        let kirora = app.start(fetchUserToken: { calls.withLock { $0 += 1 }; return fresh }, trackSessions: false)
        // Expires 61 seconds from the clock's now: refreshed in about a second.
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_000_000, expiresIn: 61))
        #expect(calls.current == 0)
        #expect(await eventually(3) { calls.current == 1 })
        // Called; the token it answered is kept as it returns.
        await settle(0.05)
        kirora.track("After")
        await kirora.flush()
        #expect(app.server.batches.last?.token == fresh)
        // The fresh one is two hours off: not asked again.
        await settle()
        #expect(calls.current == 1)
    }

    @Test func aTokenThatExpiredWhileInTheBackgroundIsRefreshedOnReturning() async throws {
        let app = TestApp()
        let fresh = userToken("user-1", issuedAt: 1_800_003_600)
        let calls = Locked(0)
        let kirora = app.start(fetchUserToken: { calls.withLock { $0 += 1 }; return fresh }, trackSessions: false)
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_000_000))
        app.lifecycle.fire(.background)
        app.clock.advance(3600)
        app.lifecycle.fire(.foreground)
        #expect(await eventually { calls.current == 1 })
        await settle(0.05)
        kirora.track("After")
        await kirora.flush()
        #expect(app.server.batches.last?.token == fresh)
    }

    @Test func aTokenFetchedTooCloseToItsExpiryIsNotFetchedAgainAndAgain() async throws {
        let app = TestApp()
        let calls = Locked(0)
        let kirora = app.start(fetchUserToken: {
            calls.withLock { $0 += 1 }
            // A server handing out tokens that expire in 30 seconds.
            return userToken("user-1", issuedAt: 1_800_000_000 + calls.current, expiresIn: 30)
        })
        try await kirora.identify()
        await settle(0.3)
        // The sign-in's, and one refresh at once, as it's already due.
        #expect(calls.current <= 2)
    }

    @Test func withoutFetchUserTokenNothingIsRefreshed() async throws {
        let app = TestApp()
        let kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_000_000, expiresIn: 30))
        kirora.track("One")
        await kirora.flush()
        #expect(app.server.batches.last?.token == userToken("user-1", issuedAt: 1_800_000_000, expiresIn: 30))
    }

    @Test func noRefreshAfterSigningOut() async throws {
        let app = TestApp()
        let calls = Locked(0)
        let kirora = app.start(fetchUserToken: { calls.withLock { $0 += 1 }; return userToken("user-1") })
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_000_000, expiresIn: 61))
        await kirora.logout()
        await settle(1.5)
        #expect(calls.current == 0)
    }

    /// No request may follow to report it: an expired token that can't be refreshed is told
    /// to the app by itself, once.
    @Test func anExpiredTokenThatCantBeRefreshedIsFetchFailed() async throws {
                let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = app.start(
            fetchUserToken: { throw TokenServerDown() },
            onAuthenticationFailed: { reason in reasons.withLock { $0.append(reason) } }, trackSessions: false
        )
        // Expired 400 seconds before the clock's now.
        try await kirora.identify(userToken("user-1", issuedAt: 1_799_996_000))
        #expect(await eventually { reasons.current == [.fetchFailed] })
        app.lifecycle.fire(.foreground)
        await settle()
        #expect(reasons.current == [.fetchFailed])
    }

    @Test func aRefreshAheadOfExpiryThatFailsIsNotReportedYet() async throws {
                let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let calls = Locked(0)
        let kirora = app.start(
            fetchUserToken: { calls.withLock { $0 += 1 }; throw TokenServerDown() },
            onAuthenticationFailed: { reason in reasons.withLock { $0.append(reason) } }, trackSessions: false
        )
        // Within the 60 seconds before expiry: refreshed at once, but still valid.
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_000_000, expiresIn: 30))
        #expect(await eventually { calls.current == 1 })
        await settle()
        #expect(reasons.current.isEmpty)
    }

    @Test func readsTheTokensExpiry() {
        #expect(SignedInUser(token: userToken("u", issuedAt: 1_800_000_000, expiresIn: 60)).tokenAndExpiry.expiry
            == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(SignedInUser(token: "not.a.token").tokenAndExpiry.expiry == nil)
        #expect(SignedInUser(token: "").tokenAndExpiry.expiry == nil)
    }
}
