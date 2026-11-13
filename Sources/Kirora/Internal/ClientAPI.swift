import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. URLSession in the app; a fake in tests.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A request still unanswered after this is abandoned and treated as a network failure.
let requestTimeoutSeconds: Double = 30

struct URLSessionTransport: HTTPTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Both: idle and in total, so a body that stops arriving can't hold a call open.
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = requestTimeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `data(for:)` is iOS 15; this works back to iOS 13.
        try await withCheckedThrowingContinuation { continuation in
            let task = Self.session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}

/// Transport for `/client/v1`: headers, errors and the user's token. On a 401 it asks
/// `identity` for a fresh token once and repeats the call.
final class ClientAPI: Sendable {
    static let defaultApiUrl = "https://api.kirora.io"

    /// Nil if `apiUrl` isn't an address: then every request fails with `urlProblem`.
    private let baseURL: URL?
    private let clientKey: String
    private let identity: Identity
    private let transport: HTTPTransport
    /// Keeps one workspace's stored state apart from another's in the same app.
    let namespace: String
    /// Why `apiUrl` can't be used, if it can't. Creating the client never throws.
    let urlProblem: String?

    init(clientKey: String, apiUrl: String, identity: Identity, transport: HTTPTransport) {
        self.clientKey = clientKey
        self.identity = identity
        self.transport = transport
        var trimmed = apiUrl
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let url = URL(string: trimmed)
        if let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           let host = url.host, !host.isEmpty {
            baseURL = url.appendingPathComponent("client/v1")
            urlProblem = nil
            namespace = "\(clientKey)@\(host)\(url.port.map { ":\($0)" } ?? "")"
        } else {
            baseURL = nil
            urlProblem = "apiUrl must be an address like \(Self.defaultApiUrl)"
            // A malformed apiUrl still gets a namespace of its own, never a real workspace's.
            namespace = "\(clientKey)@\(apiUrl)"
        }
    }

    /// Sends as `user`, or whoever is signed in now. On a 401 it asks for a fresh token
    /// once and repeats the call, but never as a different user. Returns the answer's
    /// `data`, or nil for 204.
    @discardableResult
    func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        as requestedUser: SignedInUser? = nil
    ) async throws -> JSONValue? {
        guard let baseURL else { throw KiroraError(urlProblem ?? "apiUrl is not an address") }
        guard let user = requestedUser ?? identity.user else {
            throw KiroraError("call identify() with a user token first")
        }
        let request = try makeRequest(baseURL, method, path, query, body)
        let sentToken = user.token
        if let answer = try await send(request, token: sentToken) { return answer.value }

        // Kirora refused the token: get a fresh one, once, and try again with it.
        if let freshToken = try await identity.refresh(user, refusedToken: sentToken),
           let answer = try await send(request, token: freshToken) {
            return answer.value
        }
        throw KiroraApiError(status: 401, code: "UNAUTHORIZED", message: "Kirora answered 401")
    }

    private struct Answer { let value: JSONValue? }

    /// One call. Nil for a 401, so the caller can refresh the token.
    private func send(_ template: URLRequest, token: String) async throws -> Answer? {
        var request = template
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw apiError(response, data)
        }
        if response.statusCode == 204 || data.isEmpty { return Answer(value: nil) }
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        return Answer(value: decoded?["data"])
    }

    private func makeRequest(
        _ baseURL: URL, _ method: String, _ path: String, _ query: [URLQueryItem], _ body: (any Encodable & Sendable)?
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath += path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw KiroraError("can't make an address for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = method
        request.setValue(clientKey, forHTTPHeaderField: "Kirora-Client-Key")
        request.setValue(sdkName, forHTTPHeaderField: "Kirora-SDK")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}

private func apiError(_ response: HTTPURLResponse, _ data: Data) -> KiroraApiError {
    let error = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]
    return KiroraApiError(
        status: response.statusCode,
        code: error?["code"]?.stringValue,
        message: error?["message"]?.stringValue ?? "Kirora answered \(response.statusCode)",
        retryAfterMs: retryAfterMs(response.value(forHTTPHeaderField: "Retry-After"))
    )
}

/// `Retry-After` as seconds or an HTTP date (RFC 9110), in milliseconds from now.
func retryAfterMs(_ header: String?, now: Date = Date()) -> Int? {
    guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
    let delayMs: Double
    if let seconds = Double(header) {
        delayMs = seconds * 1000
    } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        delayMs = date.timeIntervalSince(now) * 1000
    }
    // `Double` takes "1e30", "inf" and "nan" too: only a finite, positive delay counts, and
    // one past a week is cut to a week rather than overflowing `Int`.
    guard delayMs.isFinite, delayMs > 0 else { return nil }
    return Int(min(delayMs, maxWaitSeconds * 1000))
}
