import Foundation

/// One signed-in user. A new object each time the user changes, so work started for a user
/// captures it, and `identity.user === user` tells whether that user is still signed in. A
/// refreshed token replaces `token` on the same object.
final class SignedInUser: @unchecked Sendable {
    /// The token, and its `exp` (unverified, or nil), read once per token.
    private let current: Locked<(token: String, expiry: Date?)>
    /// Tells users apart, e.g. to own their queued events: the token's `sub`, unverified
    /// (Kirora checks the signature). A token without one can't be told apart from another
    /// user's, so it gets an id of its own, new for each sign-in.
    let subject: String
    /// The token's `sub`, or nil. A refreshed token must have the same.
    let tokenSubject: String?

    init(token: String) {
        let claims = claimsOf(token)
        current = Locked((token, claims.expiry))
        tokenSubject = claims.subject
        subject = tokenSubject ?? "\(unnamedSubjectPrefix)\(newId())"
    }

    var token: String {
        get { current.current.token }
        set {
            let expiry = claimsOf(newValue).expiry
            current.withLock { $0 = (newValue, expiry) }
        }
    }

    /// The token and its `exp`, together.
    var tokenAndExpiry: (token: String, expiry: Date?) { current.current }

    private let refusedFlag = Locked(false)
    /// Kirora refused this user's token with nothing to replace it (no `fetchUserToken`):
    /// nothing is sent as them again. The next identify() signs in a new user.
    var tokenRefused: Bool { refusedFlag.current }
    func refuseToken() { refusedFlag.withLock { $0 = true } }

    private let confirmedFlag = Locked(false)
    /// Kirora has accepted this user's token at least once.
    var confirmed: Bool { confirmedFlag.current }
    func confirm() {
        confirmedFlag.withLock { $0 = true }
        failureReported.withLock { $0 = false }
    }

    /// The app was told this user's token failed, and no request has succeeded since.
    private let failureReported = Locked(false)
    /// True if the app is still to be told of a failure: once per failure, not per retry.
    func claimFailureReport() -> Bool { failureReported.claimOnce() }
}

/// Who is signed in, and every rule for moving from one user to the next:
///
/// - The latest `signIn()` or `end()` wins, whatever order tokens arrive in. `signOut()`
///   only signs out the user it names, so a newer sign-in still wins.
/// - Work started for one user never carries on as the next: it captures `user`.
/// - A refused token is refreshed once, shared by every call that was refused.
///
/// The token is kept in memory only.
final class Identity: @unchecked Sendable {
    private struct State {
        var user: SignedInUser?
        /// Counts signIn() and end() calls, so only the latest sets the user.
        var calls = 0
        var signingIn: Task<Void, Error>?
        var pendingRefresh: Task<String, Error>?
        /// The user `logout()` is signing out: still signed in to send and detach, but new
        /// events and app opens no longer join them.
        var leaving: SignedInUser?
        /// Refreshes the token shortly before it expires.
        var refreshTimer: Task<Void, Never>?

        /// No one is signed in, or signing out; nothing is pending for whoever was.
        mutating func clearUser() {
            user = nil
            leaving = nil
            pendingRefresh = nil
            refreshTimer?.cancel()
            refreshTimer = nil
        }
    }

    private let state = Locked(State())
    private let fetchUserToken: (@Sendable () async throws -> String?)?
    private let tokenTimeout: Double
    /// The device's clock, against the token's `exp`.
    private let now: @Sendable () -> Date
    /// The app's `onAuthenticationFailed`.
    private let onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)?
    /// True while a public method makes the call and throws its failure to the app itself:
    /// then `onAuthenticationFailed` isn't told.
    @TaskLocal static var callerHearsFailures = false

    init(
        fetchUserToken: (@Sendable () async throws -> String?)?, tokenTimeout: Double = 30,
        onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetchUserToken = fetchUserToken
        self.tokenTimeout = tokenTimeout
        self.onAuthenticationFailed = onAuthenticationFailed
        self.now = now
    }

    var user: SignedInUser? { state.withLock { $0.user } }

    /// `user`'s token failed outside any call the app made: tells `onAuthenticationFailed`,
    /// once per failure (again only after a request succeeds, or a new identify()).
    ///
    /// Not when a public method throws the failure to the app itself
    /// (``callerHearsFailures``): that counts as telling it, so work failing alongside isn't
    /// told again. Waits for a sign-in under way, which may throw the same failure; then
    /// checks, on the main actor just before telling the app, that `user` is still the one
    /// signed in.
    func reportFailure(_ reason: AuthenticationFailureReason, as user: SignedInUser) {
        guard let onAuthenticationFailed, !Task.isCancelled else { return }
        if Self.callerHearsFailures {
            _ = user.claimFailureReport()
            return
        }
        Task.detached {
            await self.settled()
            await MainActor.run {
                guard self.capturingUser === user, user.claimFailureReport() else { return }
                onAuthenticationFailed(reason)
            }
        }
    }

    /// Who new activity belongs to: the signed-in user, unless they're signing out.
    var capturingUser: SignedInUser? {
        state.withLock { state in state.user === state.leaving ? nil : state.user }
    }

    var capturingSubject: String? { capturingUser?.subject }

    /// `user` is signing out: nothing new joins them from now on.
    func beginSignOut(_ user: SignedInUser) {
        state.withLock { state in
            if state.user === user { state.leaving = user }
        }
    }

    /// Signs in with `token`, or one from `fetchUserToken`, then runs `onSignedIn`. Does
    /// nothing if a later signIn() or end() has decided who's signed in meanwhile.
    func signIn(
        token: String?,
        onSignedIn: @escaping @Sendable () async throws -> Void
    ) async throws {
        // Counted and recorded together, so `signingIn` is always the latest call's.
        let task = state.withLock { state -> Task<Void, Error> in
            state.calls += 1
            let call = state.calls
            let task = Task {
                let userToken: String
                if let token { userToken = token } else { userToken = try await self.fetchToken() }
                let user = self.state.withLock { state -> SignedInUser? in
                    guard state.calls == call else { return nil }
                    state.user = SignedInUser(token: userToken)
                    state.leaving = nil
                    state.pendingRefresh = nil
                    return state.user
                }
                guard let user else { return }
                self.scheduleRefresh(for: user, atOnceIfDue: true)
                try await onSignedIn()
            }
            state.signingIn = task
            return task
        }
        try await task.value
    }

    /// Signs `user` out, if they're still the one signed in. True if they were.
    @discardableResult
    func signOut(_ user: SignedInUser) -> Bool {
        state.withLock { state in
            guard state.user === user else { return false }
            state.clearUser()
            return true
        }
    }

    /// Signs out whoever is signed in, abandoning any sign-in still waiting for its token.
    func end() {
        state.withLock { state in
            state.calls += 1
            state.clearUser()
        }
    }

    /// Abandons a sign-in still waiting for its token, keeping whoever is signed in now: its
    /// token, when it comes, signs no one in. Work it began once signed in carries on.
    func abandonPendingSignIn() {
        state.withLock { $0.calls += 1 }
    }

    /// Waits for the latest sign-in. Its own caller handles its errors.
    func settled() async {
        let task = state.withLock { $0.signingIn }
        _ = try? await task?.value
    }

    /// A replacement for `user`'s refused token, or nil if they're no longer signed in,
    /// there's no `fetchUserToken`, or it returned a token for someone else. Reuses a token
    /// another call already refreshed. With no `fetchUserToken`, nothing can replace it:
    /// `user` is marked refused, and nothing is sent as them again.
    func refresh(_ user: SignedInUser, refusedToken: String) async throws -> String? {
        guard self.user === user else { return nil }
        guard fetchUserToken != nil else {
            user.refuseToken()
            return nil
        }
        if user.token != refusedToken { return user.token }
        let refresh = state.withLock { state -> Task<String, Error> in
            if let pending = state.pendingRefresh { return pending }
            let task = Task { try await self.fetchToken() }
            state.pendingRefresh = task
            return task
        }
        defer {
            state.withLock { state in
                if state.pendingRefresh == refresh { state.pendingRefresh = nil }
            }
        }
        let token = try await refresh.value
        guard self.user === user, subjectOf(token) == user.tokenSubject else { return nil }
        if user.token != token {
            user.token = token
            scheduleRefresh(for: user, atOnceIfDue: false)
        }
        return token
    }

    /// The app came back to the foreground: a token that expired meanwhile is refreshed now,
    /// and the timer set again, as it may not have run while the app was suspended.
    func appCameToForeground() {
        guard let user else { return }
        scheduleRefresh(for: user, atOnceIfDue: true)
    }

    /// Fetches `user` a fresh token 60 seconds before theirs expires, as every Kirora SDK
    /// does, so a request is rarely refused for an expired one. With no `fetchUserToken`, or
    /// a token without `exp`, it waits for a refusal instead. `atOnceIfDue`: a token already
    /// that close is refreshed at once; otherwise (one just fetched) it isn't, so a server
    /// that hands out tokens shorter-lived than that isn't asked again and again.
    private func scheduleRefresh(for user: SignedInUser, atOnceIfDue: Bool) {
        let (token, expiry) = user.tokenAndExpiry
        guard fetchUserToken != nil, let expiry else { return }
        let delay = expiry.timeIntervalSince(now()) - tokenRefreshLead
        if delay <= 0, !atOnceIfDue { return }
        // Detached: the timer belongs to no caller, so a method's ``callerHearsFailures``
        // (it may be set when a refresh inside it sets this) never silences its failure.
        let timer = Task.detached { [weak self, weak user] in
            await sleep(seconds: delay)
            guard !Task.isCancelled, let self, let user else { return }
            do {
                _ = try await self.refresh(user, refusedToken: token)
            } catch is UserTokenError where self.now() >= expiry && !Task.isCancelled {
                // Expired, and no fresh one: no request may follow to report it.
                self.reportFailure(.fetchFailed, as: user)
            } catch {
                // Not yet expired: the next refusal asks again, and reports a failure then.
            }
        }
        let current = state.withLock { state -> Bool in
            guard state.user === user else { return false }
            state.refreshTimer?.cancel()
            state.refreshTimer = timer
            return true
        }
        if !current { timer.cancel() }
    }

    private func fetchToken() async throws -> String {
        guard let fetchUserToken else {
            throw KiroraError("pass identify() a user token, or set fetchUserToken")
        }
        let token: String?
        do {
            token = try await withTimeout(seconds: tokenTimeout, fetchUserToken)
        } catch {
            throw UserTokenError(error)
        }
        // No token is a failed fetch, never an empty token sent to Kirora.
        guard let token, !token.isEmpty else { throw UserTokenError(message: "fetchUserToken returned no token") }
        return token
    }
}

/// Starts the subject of a token without `sub`. Prefixed so it can't match a real one.
private let unnamedSubjectPrefix = "kirora:unnamed:"

/// True for the subject of an earlier sign-in with a token naming no one. Nobody can sign
/// in as it again, so whatever it owns can never be sent.
func isUnnamedSubject(_ subject: String) -> Bool {
    subject.hasPrefix(unnamedSubjectPrefix)
}

/// A token is refreshed this long before its `exp`.
let tokenRefreshLead: Double = 60

/// The JWT's `sub`, unverified, or nil.
func subjectOf(_ token: String) -> String? { claimsOf(token).subject }


/// The JWT's `sub` and `exp`, unverified, from one decoding.
private func claimsOf(_ token: String) -> (subject: String?, expiry: Date?) {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return (nil, nil) }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (nil, nil) }
    let subject = (claims["sub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let expiry = (claims["exp"] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
    return (subject, expiry)
}
