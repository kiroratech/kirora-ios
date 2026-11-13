import Foundation

/// One signed-in user. A new object each time the user changes, so work started for a user
/// captures it, and `identity.user === user` tells whether that user is still signed in. A
/// refreshed token replaces `token` on the same object.
final class SignedInUser: @unchecked Sendable {
    private let tokenStorage: Locked<String>
    /// Tells users apart, e.g. to own their queued events: the token's `sub`, unverified
    /// (Kirora checks the signature). A token without one can't be told apart from another
    /// user's, so it gets an id of its own, new for each sign-in.
    let subject: String
    /// The token's `sub`, or nil. A refreshed token must have the same.
    let tokenSubject: String?

    init(token: String) {
        tokenStorage = Locked(token)
        tokenSubject = subjectOf(token)
        subject = tokenSubject ?? "\(unnamedSubjectPrefix)\(newId())"
    }

    var token: String {
        get { tokenStorage.current }
        set { tokenStorage.withLock { $0 = newValue } }
    }
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
    }

    private let state = Locked(State())
    private let fetchUserToken: (@Sendable () async throws -> String)?
    private let tokenTimeout: Double

    init(fetchUserToken: (@Sendable () async throws -> String)?, tokenTimeout: Double = 30) {
        self.fetchUserToken = fetchUserToken
        self.tokenTimeout = tokenTimeout
    }

    var user: SignedInUser? { state.withLock { $0.user } }

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
                let current = self.state.withLock { state -> Bool in
                    guard state.calls == call else { return false }
                    state.user = SignedInUser(token: userToken)
                    state.pendingRefresh = nil
                    return true
                }
                if current { try await onSignedIn() }
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
            state.user = nil
            state.pendingRefresh = nil
            return true
        }
    }

    /// Signs out whoever is signed in, abandoning any sign-in still waiting for its token.
    func end() {
        state.withLock { state in
            state.calls += 1
            state.user = nil
            state.pendingRefresh = nil
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
    /// another call already refreshed.
    func refresh(_ user: SignedInUser, refusedToken: String) async throws -> String? {
        guard self.user === user, fetchUserToken != nil else { return nil }
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
        user.token = token
        return token
    }

    private func fetchToken() async throws -> String {
        guard let fetchUserToken else {
            throw KiroraError("pass identify() a user token, or set fetchUserToken")
        }
        do {
            return try await withTimeout(seconds: tokenTimeout, fetchUserToken)
        } catch {
            throw UserTokenError(error)
        }
    }
}

/// Starts the subject of a token without `sub`. Prefixed so it can't match a real one.
private let unnamedSubjectPrefix = "kirora:unnamed:"

/// True for the subject of an earlier sign-in with a token naming no one. Nobody can sign
/// in as it again, so whatever it owns can never be sent.
func isUnnamedSubject(_ subject: String) -> Bool {
    subject.hasPrefix(unnamedSubjectPrefix)
}

/// The JWT's `sub`, unverified, or nil.
func subjectOf(_ token: String) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard
        let data = Data(base64Encoded: base64),
        let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let sub = claims["sub"] as? String, !sub.isEmpty
    else { return nil }
    return sub
}
