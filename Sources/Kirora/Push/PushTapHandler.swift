import Foundation

/// Reports a push tapped to its own `trackingUrl`, which names the device and delivery, so
/// it needs no credentials and no signed-in user. A best-effort count: a network error,
/// 429 or 5xx is tried once more, then dropped. A repeat changes nothing on Kirora's side.
enum TrackingReport {
    static func post(
        _ event: String,
        to trackingUrl: URL,
        transport: HTTPTransport = URLSessionTransport()
    ) async {
        var request = URLRequest(url: trackingUrl, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["event": event])
        for _ in 0..<2 {
            guard let (_, response) = try? await transport.send(request) else { continue }
            // Any other 4xx (an expired or altered token) would be refused again.
            if response.statusCode < 500, response.statusCode != 429 { return }
        }
    }
}

/// A Kirora push's own keys, beside `aps`, whether it came through APNs or Firebase.
///
/// A push is Kirora's only if it says so: the `kirora` marker, or, from servers before the
/// marker, a `trackingUrl` at Kirora's tracking path. `actionUrl` and `imageUrl` are names
/// any provider might use, so they alone never make a push Kirora's.
struct KiroraPushPayload: Equatable, Sendable {
    /// Where to report the tap. Missing on test sends from the dashboard, which report
    /// nothing.
    var trackingUrl: URL?
    /// What a tap on the notification opens: a web link or an app link (`myapp://…`).
    var actionUrl: URL?

    init?(userInfo: [AnyHashable: Any]) {
        let trackingUrl = (userInfo["trackingUrl"] as? String).flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let marked = userInfo["kirora"] != nil
        guard marked || trackingUrl?.path.hasPrefix("/t/p/") == true else { return nil }
        self.trackingUrl = trackingUrl
        actionUrl = (userInfo["actionUrl"] as? String).flatMap(URL.init(string:)).flatMap { url in
            // As Kirora refuses them when a push is made.
            guard let scheme = url.scheme?.lowercased(),
                  !["javascript", "data", "file", "vbscript"].contains(scheme) else { return nil }
            return url
        }
    }
}

/// What to do when the user taps a notification: report it, and open its link.
struct PushTapHandler: Sendable {
    /// Whether the tap was on the notification itself, as opposed to dismissing it or a
    /// button the app registered.
    enum Action: Sendable { case open, dismiss, other }

    var transport: HTTPTransport = URLSessionTransport()
    /// Opens a link on the main thread. UIKit in the app; a fake in tests.
    var openURL: @Sendable (URL) async -> Void

    /// Handles a tap on a Kirora push.
    func handle(_ payload: KiroraPushPayload, action: Action) async {
        guard action != .dismiss else { return }
        // Opening a link counts as a click (Kirora counts a click as an open too).
        let link = action == .open ? payload.actionUrl : nil
        let transport = self.transport
        let reporting = Task {
            if let trackingUrl = payload.trackingUrl {
                await TrackingReport.post(link == nil ? "opened" : "clicked", to: trackingUrl, transport: transport)
            }
        }
        if let link { await openURL(link) }
        await reporting.value
    }
}

/// Taps the SDK has handled, so a tap passed to it twice (by its own delegate proxy and by
/// the app's manual call) is reported once.
let handledTaps = Locked(Set<String>())

func firstTimeHandling(_ id: String) -> Bool {
    handledTaps.withLock { handled in
        if handled.count > 200 { handled.removeAll() }
        return handled.insert(id).inserted
    }
}
