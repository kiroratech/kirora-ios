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

    /// A token naming no one can't be told from another user's: discarded like one, and the
    /// app told the token was refused.
    @Test func aFreshTokenWithoutASubjectIsDiscarded() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = app.start(
            fetchUserToken: { userToken(nil) },
            onAuthenticationFailed: { reason in reasons.withLock { $0.append(reason) } }
        )
        app.server.answer { _ in .error(401, "UNAUTHORIZED") }
        try await kirora.identify(userToken("user-1"))
        kirora.track("Order Completed")
        await kirora.flush()
        #expect(!app.server.batches.isEmpty)
        #expect(app.server.batches.allSatisfy { $0.token == userToken("user-1") })
        #expect(await eventually { reasons.current == [.refused] })
    }

    /// Nor after a sign-in whose own token named no one: two such tokens may be two users.
    @Test func aSubjectlessSignInTakesNoSubjectlessRefresh() async throws {
        let app = TestApp()
        let fresh = userToken(nil, issuedAt: 1_799_999_100)
        let kirora = app.start(fetchUserToken: { fresh })
        app.server.answer { _ in .error(401, "UNAUTHORIZED") }
        try await kirora.identify(userToken(nil))
        kirora.track("Order Completed")
        await kirora.flush()
        #expect(!app.server.batches.isEmpty)
        #expect(!app.server.batches.contains { $0.token == fresh })
    }

    /// The app restored its own session after a relaunch, without identify(): what's
    /// tracked continues the signed-in user's visit and waits for a sign-in, but it's theirs.
    /// Logging out drops it, so the next user never takes it as theirs (spec gap 27).
    @Test func logoutDropsWaitingEventsThatContinuedASignedInVisit() async throws {
        let app = TestApp()
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        kirora.destroy()

        kirora = app.start()
        kirora.track("A's, before identify")
        await kirora.logout()
        kirora.track("After logout")
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        #expect(!app.server.sentEventNames.contains("A's, before identify"))
        // What's tracked after the sign-out is the next user's to take, as before.
        let sentAsB = app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.eventNames)
        #expect(sentAsB.contains("After logout"))
    }

    /// A visitor who never signed in keeps theirs: a logout() on a screen before sign-up
    /// can't lose a funnel.
    @Test func logoutKeepsAVisitorsEventsFromBeforeSignIn() async throws {
        let app = TestApp()
        let kirora = app.start()
        kirora.track("Pricing Viewed")
        await kirora.logout()
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        #expect(app.server.sentEventNames.contains("Pricing Viewed"))
    }

    /// Without visits, which events continued a signed-in user's can't be told: none go.
    @Test func withoutVisitsLogoutWithNobodySignedInDropsNothing() async throws {
        let app = TestApp()
        var kirora = app.start(trackSessions: false)
        try await kirora.identify(userToken("A"))
        kirora.destroy()
        kirora = app.start(trackSessions: false)
        kirora.track("Before identify")
        await kirora.logout()
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        #expect(app.server.sentEventNames.contains("Before identify"))
    }

    /// A sign-in still under way as logout() begins is the user signing out: it adopts the
    /// waiting events first, so they're sent as that user, not dropped.
    @Test func logoutLetsAPendingSignInAdoptWaitingEventsFirst() async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("A")
        }, trackSessions: false)
        kirora.track("Before sign-in")
        let signIn = Task { try await kirora.identify() }
        await settle(0.05)
        await kirora.logout()
        _ = try? await signIn.value
        let sentAsA = app.server.batches.filter { subjectOf($0.token ?? "") == "A" }.flatMap(\.eventNames)
        #expect(sentAsA.contains("Before sign-in"))
    }

    /// An identify() made while logout waits for a sign-in under way comes after the logout:
    /// that user stays signed in.
    @Test func anIdentifyDuringLogoutsWaitIsNotSignedOut() async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("B")
        }, trackSessions: false)
        try await kirora.identify(userToken("A"))
        let signIn = Task { try? await kirora.identify() }
        await settle(0.05)
        let logout = Task { await kirora.logout() }
        await settle(0.05)
        try await kirora.identify(userToken("C"))
        await logout.value
        await signIn.value
        kirora.track("After")
        await kirora.flush()
        let sentAsC = app.server.batches.filter { subjectOf($0.token ?? "") == "C" }.flatMap(\.eventNames)
        #expect(sentAsC.contains("After"))
    }

    /// A slow identify() begun during the logout isn't what it waits for, nor abandoned
    /// when that wait runs out.
    @Test func aSlowIdentifyDuringLogoutIsNotAbandoned() async throws {
        let app = TestApp()
        app.logoutWait = 0.2
        let fetches = Locked(0), loggedOut = Locked(false)
        let kirora = app.start(fetchUserToken: {
            let fetch = fetches.withLock { $0 += 1; return $0 }
            if fetch == 1 {
                // B's token outlasts the logout's wait.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return userToken("B")
            }
            // C's arrives only once the logout is over.
            while !loggedOut.current { try await Task.sleep(nanoseconds: 10_000_000) }
            return userToken("C")
        }, trackSessions: false)
        try await kirora.identify(userToken("A"))
        let signInB = Task { try? await kirora.identify() }
        #expect(await eventually { fetches.current == 1 })
        let logout = Task { await kirora.logout() }
        await settle(0.02)
        let signInC = Task { try await kirora.identify() }
        #expect(await eventually { fetches.current == 2 })
        await logout.value
        loggedOut.withLock { $0 = true }
        try await signInC.value
        signInB.cancel()
        kirora.track("After")
        await kirora.flush()
        let sentAsC = app.server.batches.filter { subjectOf($0.token ?? "") == "C" }.flatMap(\.eventNames)
        #expect(sentAsC.contains("After"))
    }

    /// A sign-in under way as logout began, landing during it, adopts only what was waiting
    /// then: what's tracked during the logout is the next user's.
    @Test func aSignInLandingDuringLogoutLeavesWhatsTrackedMeanwhile() async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("B")
        }, trackSessions: false)
        let signIn = Task { try? await kirora.identify() }
        await settle(0.05)
        let logout = Task { await kirora.logout() }
        await settle(0.05)
        kirora.track("During logout")
        await logout.value
        await signIn.value
        try await kirora.identify(userToken("C"))
        await kirora.flush()
        let asB = app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.eventNames)
        let asC = app.server.batches.filter { subjectOf($0.token ?? "") == "C" }.flatMap(\.eventNames)
        #expect(!asB.contains("During logout"))
        #expect(asC.contains("During logout"))
    }

    /// An identify() during logout never takes what was waiting as the logout began: the
    /// outgoing user's.
    @Test func anIdentifyDuringLogoutDoesntTakeWhatWasWaiting() async throws {
        let app = TestApp()
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        kirora.destroy()
        kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("B")
        })
        let relaunched = kirora
        relaunched.track("A's, before identify")
        let signIn = Task { try? await relaunched.identify() }
        await settle(0.05)
        let logout = Task { await relaunched.logout() }
        await settle(0.05)
        try await relaunched.identify(userToken("C"))
        await logout.value
        await signIn.value
        await relaunched.flush()
        let asC = app.server.batches.filter { subjectOf($0.token ?? "") == "C" }.flatMap(\.eventNames)
        #expect(!asC.contains("A's, before identify"))
    }

    /// The same for an event still in `beforeSend` as the logout begins: it's held with the
    /// rest, not given to the identify() made during the logout.
    @Test func anEventInBeforeSendAsLogoutBeginsIsHeldToo() async throws {
        let app = TestApp()
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        kirora.destroy()
        kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("B")
        }, beforeSend: { event in
            if event.name == "Slow" { Thread.sleep(forTimeInterval: 0.2) }
            return event
        })
        let relaunched = kirora
        let tracking = Task.detached { relaunched.track("Slow") }
        await settle(0.02)
        let signIn = Task { try? await relaunched.identify() }
        await settle(0.03)
        let logout = Task { await relaunched.logout() }
        await settle(0.03)
        try await relaunched.identify(userToken("C"))
        await tracking.value
        await logout.value
        await signIn.value
        await relaunched.flush()
        let asC = app.server.batches.filter { subjectOf($0.token ?? "") == "C" }.flatMap(\.eventNames)
        #expect(!asC.contains("Slow"))
    }

    /// A second logout, called after an identify() made during the first, signs that user
    /// out too, however the two overlap.
    @Test func overlappingLogoutsSignOutAnIdentifyBetweenThem() async throws {
        let app = TestApp()
        app.logoutWait = 0.3
        let fetches = Locked(0)
        let kirora = app.start(fetchUserToken: {
            let fetch = fetches.withLock { $0 += 1; return $0 }
            if fetch == 1 { try await Task.sleep(nanoseconds: 2_000_000_000); return userToken("B") }
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("C")
        }, trackSessions: false)
        try await kirora.identify(userToken("A"))
        let signInB = Task { try? await kirora.identify() }
        #expect(await eventually { fetches.current == 1 })
        let logout1 = Task { await kirora.logout() }
        await settle(0.1)
        let signInC = Task { try? await kirora.identify() }
        #expect(await eventually { fetches.current == 2 })
        let logout2 = Task { await kirora.logout() }
        await logout1.value
        await logout2.value
        await signInC.value
        signInB.cancel()
        #expect(!kirora.getState().isIdentified)
    }

    /// The same with nobody signed in as logout began: C's registration isn't detached by
    /// the device secret.
    @Test func anIdentifyDuringALogoutWithNobodySignedInKeepsItsRegistration() async throws {
        let app = TestApp()
        let kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 300_000_000)
            return userToken("B")
        }, push: .enabled, trackSessions: false)
        let signIn = Task { try? await kirora.identify() }
        await settle(0.05)
        let logout = Task { await kirora.logout() }
        await settle(0.05)
        try await kirora.identify(userToken("C"))
        await logout.value
        await signIn.value
        await settle(0.1)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.isEmpty)
        #expect(kirora.push.registered)
    }

    /// Logout waits for a sign-in under way, here one that never comes. What was waiting as
    /// it began, on A's restored visit, is dropped; what's tracked during that wait is the
    /// next user's, as anything tracked during a logout is.
    @Test func whatIsTrackedWhileLogoutWaitsGoesToTheNextUser() async throws {
        let app = TestApp()
        app.logoutWait = 0.4
        var kirora = app.start()
        try await kirora.identify(userToken("A"))
        kirora.track("A's")
        await kirora.flush()
        kirora.destroy()

        kirora = app.start(fetchUserToken: {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return userToken("A")
        })
        let relaunched = kirora
        relaunched.track("Before logout")
        let signIn = Task { try? await relaunched.identify() }
        await settle(0.05)
        let logout = Task { await relaunched.logout() }
        await settle(0.1)
        kirora.track("During logout")
        await logout.value
        signIn.cancel()
        try await kirora.identify(userToken("B"))
        await kirora.flush()
        let sentAsB = app.server.batches.filter { subjectOf($0.token ?? "") == "B" }.flatMap(\.eventNames)
        #expect(sentAsB.contains("During logout"))
        #expect(!app.server.sentEventNames.contains("Before logout"))
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

    /// No request may follow to report it: a token that expired while the app was away and
    /// can't be refreshed is told to the app by itself, once.
    @Test func anExpiredTokenThatCantBeRefreshedIsFetchFailed() async throws {
        let app = TestApp()
        let reasons = Locked<[AuthenticationFailureReason]>([])
        let kirora = app.start(
            fetchUserToken: { throw TokenServerDown() },
            onAuthenticationFailed: { reason in reasons.withLock { $0.append(reason) } }, trackSessions: false
        )
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_000_000))
        app.lifecycle.fire(.background)
        app.clock.advance(4000)
        app.lifecycle.fire(.foreground)
        #expect(await eventually { reasons.current == [.fetchFailed] })
        app.lifecycle.fire(.foreground)
        await settle()
        #expect(reasons.current == [.fetchFailed])
    }

    /// A device whose clock is ahead: every token looks expired as it arrives. Its lifetime
    /// counts from now, so it's used, not fetched again at once, and refreshed ahead.
    @Test func aTokenExpiredOnArrivalHasItsLifetimeCountedFromNow() async throws {
        let app = TestApp()
        let calls = Locked(0)
        let kirora = app.start(
            fetchUserToken: { calls.withLock { $0 += 1 }; return userToken("user-1", issuedAt: 1_799_990_000, expiresIn: 7200) },
            trackSessions: false
        )
        // Issued, by the device's clock, 10,000 seconds ago, lasting 61.
        let token = userToken("user-1", issuedAt: 1_799_990_000, expiresIn: 61)
        try await kirora.identify(token)
        kirora.track("One")
        await kirora.flush()
        #expect(app.server.batches.last?.token == token)
        #expect(calls.current == 0)
        // Refreshed about a second on, 60 seconds before its counted end.
        #expect(await eventually(3) { calls.current == 1 })
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

    /// A device whose clock is behind: the token's lifetime counts from now, so its refresh
    /// still comes 60 seconds before it runs out, not an hour late.
    @Test func aTokenIssuedAheadOfTheClockIsRefreshedOnTimeByIt() async throws {
        let app = TestApp()
        let calls = Locked(0)
        let kirora = app.start(
            fetchUserToken: { calls.withLock { $0 += 1 }; return userToken("user-1", issuedAt: 1_800_003_600, expiresIn: 7200) },
            trackSessions: false
        )
        // Issued an hour ahead of the clock, lasting 61 seconds: refreshed in about a second.
        try await kirora.identify(userToken("user-1", issuedAt: 1_800_003_600, expiresIn: 61))
        #expect(await eventually(3) { calls.current == 1 })
    }

    @Test func countsTheLifetimeOfATokenIssuedAheadOfTheClockFromNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ahead = claimsOf(userToken("u", issuedAt: 1_800_003_600, expiresIn: 600))
        #expect(expiryOf(ahead, now: now) == now.addingTimeInterval(600))
        // Up to the 60-second lead is ordinary skew: `exp` as it is.
        let slightly = claimsOf(userToken("u", issuedAt: 1_800_000_060, expiresIn: 600))
        #expect(expiryOf(slightly, now: now) == Date(timeIntervalSince1970: 1_800_000_660))
        // Already expired as it arrives: from now too.
        let expired = claimsOf(userToken("u", issuedAt: 1_799_990_000, expiresIn: 600))
        #expect(expiryOf(expired, now: now) == now.addingTimeInterval(600))
        // Expired, with no `iat` to tell its lifetime: not known, so it waits for a refusal.
        #expect(expiryOf(TokenClaims(subject: "u", expiry: now.addingTimeInterval(-10)), now: now) == nil)
        // No `iat`: `exp` as it is.
        let undated = TokenClaims(subject: "u", expiry: Date(timeIntervalSince1970: 1_800_009_000))
        #expect(expiryOf(undated, now: now) == undated.expiry)
    }

    @Test func readsTheTokensExpiry() {
        #expect(SignedInUser(token: userToken("u", issuedAt: 1_800_000_000, expiresIn: 60), now: Date(timeIntervalSince1970: 1_800_000_000)).tokenAndExpiry.expiry
            == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(SignedInUser(token: "not.a.token").tokenAndExpiry.expiry == nil)
        #expect(SignedInUser(token: "").tokenAndExpiry.expiry == nil)
    }
}
