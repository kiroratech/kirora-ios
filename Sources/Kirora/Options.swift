import Foundation

/// How a ``Kirora`` client is set up. Only ``clientKey`` is required.
///
/// The same options, with the same names and defaults, exist in every Kirora client SDK.
public struct KiroraOptions: Sendable {
    /// The workspace's public key, `kirora_pk_…`, from Developer → SDK in the dashboard.
    /// Safe to ship in the app.
    public var clientKey: String

    /// Asks your server for a signed user token. Called by ``Kirora/identify(_:)`` without a
    /// token, and again when Kirora refuses an expired one. Throw if it fails: queued
    /// events are kept. One that hasn't answered after 30 seconds counts as failed.
    public var fetchUserToken: (@Sendable () async throws -> String)?

    /// Registers this device for push notifications. Off (`nil`) by default; pass
    /// ``PushOptions/enabled`` for the defaults.
    public var push: PushOptions?

    /// Track and store nothing until ``Kirora/setTrackingConsent(_:)`` is called with
    /// `true`, e.g. for users in the EU or UK.
    public var requireTrackingConsent: Bool

    /// Tracks `Session Started` when a visit begins and adds `context.sessionId` to every
    /// event. On by default. A visit ends after 30 minutes without activity; time in the
    /// foreground never ends one.
    public var trackSessions: Bool

    /// Tracks `Application Installed`, `Application Opened`, `Application Updated` and
    /// `Application Backgrounded`. Off by default.
    public var trackAppLifecycle: Bool

    /// What the SDK logs. Defaults to ``LogLevel/error``; ``LogLevel/debug`` also logs
    /// what is sent.
    public var logLevel: LogLevel

    /// Called on the main thread with a push's link when the user taps it. Return `true` if
    /// your app opened it itself. Otherwise the SDK opens it: a universal link in your app
    /// (through your scene or app delegate), anything else with `UIApplication.open`.
    public var handleDeepLink: (@MainActor @Sendable (URL) -> Bool)?

    /// Kirora's address, for staging or a private deployment, without a path: the SDK
    /// adds its own. Defaults to `https://api.kirora.io`.
    public var apiUrl: String

    public init(
        clientKey: String,
        fetchUserToken: (@Sendable () async throws -> String)? = nil,
        push: PushOptions? = nil,
        requireTrackingConsent: Bool = false,
        trackSessions: Bool = true,
        trackAppLifecycle: Bool = false,
        logLevel: LogLevel = .error,
        handleDeepLink: (@MainActor @Sendable (URL) -> Bool)? = nil,
        apiUrl: String = "https://api.kirora.io"
    ) {
        self.handleDeepLink = handleDeepLink
        self.clientKey = clientKey
        self.fetchUserToken = fetchUserToken
        self.push = push
        self.requireTrackingConsent = requireTrackingConsent
        self.trackSessions = trackSessions
        self.trackAppLifecycle = trackAppLifecycle
        self.logLevel = logLevel
        self.apiUrl = apiUrl
    }
}

/// Push settings. Everything else about push (the APNs credential, the push app) comes
/// from Kirora, not the app.
public struct PushOptions: Sendable, Equatable {
    /// Only needed if the workspace has more than one iOS push app: the one to register
    /// with. Kirora chooses otherwise.
    public var pushAppId: String?

    public init(pushAppId: String? = nil) {
        self.pushAppId = pushAppId
    }

    /// Push on, with Kirora choosing the push app.
    public static let enabled = PushOptions()
}

/// The answer to ``Kirora/requestPushPermission()``. The same values in every Kirora SDK.
public enum PushPermission: String, Sendable, Equatable {
    case granted
    case denied
    /// The user dismissed the prompt without answering.
    case unanswered
    /// Push is off in ``KiroraOptions/push``, or the platform can't take pushes.
    case unsupported
}

/// What the SDK logs.
public enum LogLevel: String, Sendable, Comparable {
    case none
    case error
    case debug

    private var rank: Int {
        switch self {
        case .none: return 0
        case .error: return 1
        case .debug: return 2
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}
