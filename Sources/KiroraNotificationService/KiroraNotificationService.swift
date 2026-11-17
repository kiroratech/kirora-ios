#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// Reports Kirora pushes delivered, and shows their images, from your app's Notification
/// Service Extension. Kirora sets `mutable-content` on every iOS push, so the extension
/// always runs. Without one, iOS reports no deliveries and shows no images.
///
/// The simplest extension is a subclass:
///
/// ```swift
/// import KiroraNotificationService
///
/// class NotificationService: KiroraNotificationServiceExtension {}
/// ```
///
/// Or call it from your own extension, which handles everyone else's pushes:
///
/// ```swift
/// override func didReceive(_ request: UNNotificationRequest,
///                          withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
///     if KiroraNotificationService.didReceive(request, withContentHandler: contentHandler) { return }
///     // Not a Kirora push: your own handling, then contentHandler(…)
/// }
///
/// override func serviceExtensionTimeWillExpire() {
///     KiroraNotificationService.serviceExtensionTimeWillExpire()
/// }
/// ```
public enum KiroraNotificationService {
    /// Handles a Kirora push: reports it delivered, attaches its image, then hands it to
    /// `contentHandler`, whatever Kirora answered. Returns false, without calling
    /// `contentHandler`, for anyone else's push.
    @discardableResult
    public static func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) -> Bool {
        guard let (trackingUrl, imageUrl) = kiroraPush(request.content.userInfo) else { return false }
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let delivery = PendingDelivery(content: content, contentHandler: contentHandler)
        let id = request.identifier
        active.withLock { $0[id] = delivery }
        Task {
            // Together: iOS gives an extension about 30 seconds in all.
            let reporting = Task { await report(trackingUrl) }
            if let imageUrl, let attachment = await downloadAttachment(imageUrl) { delivery.attach(attachment) }
            await reporting.value
            delivery.finish()
            active.withLock { _ = $0.removeValue(forKey: id) }
        }
        return true
    }

    /// iOS is about to stop the extension: shows every Kirora push still being worked on
    /// as it stands.
    public static func serviceExtensionTimeWillExpire() {
        let deliveries = active.withLock { active -> [PendingDelivery] in
            defer { active.removeAll() }
            return Array(active.values)
        }
        deliveries.forEach { $0.finish() }
    }

    /// A Kirora push's tracking and image addresses, or nil for anyone else's push. Kirora's
    /// carries the `kirora` marker; `trackingUrl` and `imageUrl` are names any provider might
    /// use, so they alone never count.
    static func kiroraPush(_ userInfo: [AnyHashable: Any]) -> (trackingUrl: URL?, imageUrl: URL?)? {
        guard userInfo["kirora"] != nil else { return nil }
        let trackingUrl = (userInfo["trackingUrl"] as? String).flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let imageUrl = (userInfo["imageUrl"] as? String).flatMap(URL.init(string:))
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        return (trackingUrl, imageUrl)
    }

    /// The pushes being worked on, by request id.
    private static let active = Locked<[String: PendingDelivery]>([:])

    /// Posts `delivered` to the push's own `trackingUrl`, which names the device and needs
    /// no credentials. A best-effort count: a network error, 429 or 5xx is tried once more,
    /// then dropped. A push without one (a test send) reports nothing.
    static func report(_ trackingUrl: URL?, session: URLSession = .shared) async {
        guard let trackingUrl else { return }
        var request = URLRequest(url: trackingUrl, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"event":"delivered"}"#.utf8)
        for _ in 0..<2 {
            let status = await send(request, session: session)
            // Any other 4xx (an expired or altered token) would be refused again.
            if let status, status < 500, status != 429 { return }
        }
    }

    private static func send(_ request: URLRequest, session: URLSession) async -> Int? {
        await withCheckedContinuation { continuation in
            session.dataTask(with: request) { _, response, _ in
                continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode)
            }.resume()
        }
    }

    /// Downloads the push's image as an attachment, or nil if it can't be had in time.
    static func downloadAttachment(_ url: URL, session: URLSession = .shared) async -> UNNotificationAttachment? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 20)
        return await withCheckedContinuation { continuation in
            session.downloadTask(with: request) { location, response, _ in
                guard let location, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continuation.resume(returning: nil)
                    return
                }
                // iOS reads the image's type from its file extension.
                let fileExtension = imageExtension(mimeType: http.mimeType, url: url)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kirora-\(UUID().uuidString)", isDirectory: true)
                let file = directory.appendingPathComponent("image.\(fileExtension)")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: location, to: file)
                    continuation.resume(returning: try UNNotificationAttachment(identifier: "kirora-image", url: file))
                } catch {
                    continuation.resume(returning: nil)
                }
            }.resume()
        }
    }

    static func imageExtension(mimeType: String?, url: URL) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:
            let fromUrl = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(fromUrl) ? fromUrl : "jpg"
        }
    }
}

/// One push being worked on. Hands its content over exactly once, whichever comes first:
/// the work finishing or iOS's time running out.
private final class PendingDelivery: @unchecked Sendable {
    private let state: Locked<(content: UNMutableNotificationContent, handler: ((UNNotificationContent) -> Void)?)>

    init(content: UNMutableNotificationContent, contentHandler: @escaping (UNNotificationContent) -> Void) {
        state = Locked((content, contentHandler))
    }

    func attach(_ attachment: UNNotificationAttachment) {
        state.withLock { state in
            if state.handler != nil { state.content.attachments = [attachment] }
        }
    }

    func finish() {
        let (content, handler) = state.withLock { state -> (UNNotificationContent, ((UNNotificationContent) -> Void)?) in
            defer { state.handler = nil }
            return (state.content, state.handler)
        }
        handler?(content)
    }
}

/// A Notification Service Extension that handles Kirora pushes and passes anyone else's
/// through unchanged. Subclass it as your extension's principal class; override
/// `didReceive` to handle other pushes, calling `super` for Kirora's.
open class KiroraNotificationServiceExtension: UNNotificationServiceExtension {
    override open func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if !KiroraNotificationService.didReceive(request, withContentHandler: contentHandler) {
            contentHandler(request.content)
        }
    }

    override open func serviceExtensionTimeWillExpire() {
        KiroraNotificationService.serviceExtensionTimeWillExpire()
    }
}

/// A value guarded by a lock. This target depends on nothing, so it has its own.
fileprivate final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
#endif
