import Foundation

/// A problem the SDK reports that isn't one of Kirora's answers: no user token to sign in
/// with, or an `apiUrl` that isn't an address.
public struct KiroraError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String { "Kirora: \(message)" }
    public var errorDescription: String? { description }
}

/// The app's `fetchUserToken` failed or didn't answer within 30 seconds. Queued events
/// are kept and retried later.
public struct UserTokenError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// What `fetchUserToken` threw, or a timeout.
    public let underlying: Error

    init(_ underlying: Error) {
        self.underlying = underlying
    }

    public var description: String { "Kirora: fetchUserToken failed: \(underlying)" }
    public var errorDescription: String? { description }
}

/// An error answer from the Kirora API.
public struct KiroraApiError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// The HTTP status.
    public let status: Int
    /// Kirora's error code, such as `UNAUTHORIZED` or `RATE_LIMITED`, if it sent one.
    public let code: String?
    public let message: String
    /// From the `Retry-After` header, if any.
    public let retryAfterMs: Int?

    init(status: Int, code: String?, message: String, retryAfterMs: Int? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfterMs = retryAfterMs
    }

    /// True for 408, 425, 429 and 5xx: the same call may succeed later.
    public var isRetryable: Bool { [408, 425, 429].contains(status) || status >= 500 }

    public var description: String {
        "Kirora: \(message) (\(status)\(code.map { " \($0)" } ?? ""))"
    }

    public var errorDescription: String? { description }
}
