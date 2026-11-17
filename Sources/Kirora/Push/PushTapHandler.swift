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
/// A push is Kirora's only if it carries the `kirora` marker. `trackingUrl`, `actionUrl` and
/// `imageUrl` are names any provider might use, so they alone never make a push Kirora's.
struct KiroraPushPayload: Equatable, Sendable {
    /// Where to report the tap. Missing on test sends from the dashboard, which report
    /// nothing.
    var trackingUrl: URL?
    /// What a tap on the notification opens: a web link or an app link (`myapp://…`).
    var actionUrl: URL?
    /// The push's buttons, in order. iOS shows them only for a notification category the
    /// app registers; an action's identifier names its button by position (`"0"`, `"1"`)
    /// or by title.
    var buttons: [Button] = []

    struct Button: Equatable, Sendable {
        var title: String
        var url: URL?
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["kirora"] != nil else { return nil }
        trackingUrl = (userInfo["trackingUrl"] as? String).flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        actionUrl = safeLink(userInfo["actionUrl"] as? String)
        buttons = Self.buttons(userInfo["buttons"])
    }

    /// The button an action identifier names, by its position or its title.
    func buttonIndex(for actionIdentifier: String) -> Int? {
        if let index = Int(actionIdentifier), buttons.indices.contains(index) { return index }
        return buttons.firstIndex { $0.title == actionIdentifier }
    }

    /// The link of the button an action identifier names, if any.
    func buttonLink(for actionIdentifier: String) -> URL? {
        buttonIndex(for: actionIdentifier).flatMap { buttons[$0].url }
    }

    /// `buttons` as Kirora sends it: JSON text (native pushes carry string data), or an array.
    private static func buttons(_ value: Any?) -> [Button] {
        var list: Any? = value
        if let text = value as? String, let data = text.data(using: .utf8) {
            list = try? JSONSerialization.jsonObject(with: data)
        }
        guard let items = list as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            return Button(title: title, url: safeLink(item["url"] as? String))
        }
    }
}

/// A link Kirora would send: any scheme but those it refuses when a push is made.
private func safeLink(_ text: String?) -> URL? {
    guard let url = text.flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(),
          !["javascript", "data", "file", "vbscript"].contains(scheme) else { return nil }
    return url
}

/// What to do when the user taps a notification: report it, and open its link.
struct PushTapHandler: Sendable {
    /// Whether the tap was on the notification itself, on one of its buttons (by the
    /// action's identifier), or dismissed it.
    enum Action: Sendable, Equatable { case open, dismiss, button(String) }

    var transport: HTTPTransport = URLSessionTransport()
    /// Opens a link on the main thread. UIKit in the app; a fake in tests.
    var openURL: @Sendable (URL) async -> Void

    /// Handles a tap on a Kirora push: reports it and opens its link, then tells `tapped` (a
    /// wrapper's listener) which link it opened. The report goes first: `tapped` waits for
    /// it, but no more than 1.5 seconds, so a slow network can't hold the app's tap event.
    func handle(_ payload: KiroraPushPayload, action: Action, tapped: (@Sendable (URL?) -> Void)? = nil) async {
        guard action != .dismiss else { return }
        // Opening a link counts as a click (Kirora counts a click as an open too).
        let link: URL?
        switch action {
        case .open: link = payload.actionUrl
        case .button(let identifier): link = payload.buttonLink(for: identifier)
        case .dismiss: link = nil
        }
        let transport = self.transport
        let reporting = Task {
            if let trackingUrl = payload.trackingUrl {
                await TrackingReport.post(link == nil ? "opened" : "clicked", to: trackingUrl, transport: transport)
            }
        }
        if let link { await openURL(link) }
        if let tapped {
            _ = try? await withTimeout(seconds: wrapperCallbackTimeout) { await reporting.value }
            tapped(link)
        }
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
