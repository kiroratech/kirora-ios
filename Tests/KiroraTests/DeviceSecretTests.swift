import Foundation
import Testing
@testable import Kirora

private func deletes(_ app: TestApp) -> [SentRequest] {
    app.server.requests.filter { $0.method == "DELETE" }
}

private func registrations(_ app: TestApp) -> [SentRequest] {
    app.server.requests.filter { $0.method == "PUT" && $0.path.hasPrefix("/client/v1/devices/") }
}

/// Signing out with no user token held: by the secret the SDK made for the installation
/// and sends with every registration (spec, "Device cleanup after sign-out", 22 November).
@Suite("Device secret")
struct DeviceSecretTests {
    /// One per installation: 32 random bytes, base64url, the same in every registration,
    /// the denied form included, and kept as long as the device id.
    @Test func everyRegistrationSendsTheInstallationsSecret() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        // B signs in with notifications off: the denied form takes the device over.
        app.push.status.withLock { $0 = .denied }
        try await kirora.identify(userToken("B"))
        let sent = registrations(app).map(\.deviceSecret)
        #expect(sent.count == 2)
        let secret = try #require(sent.first ?? nil)
        #expect(sent.allSatisfy { $0 == secret })
        #expect(secret.count == 43)
        #expect(secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(app.stored(StorageKeys.deviceSecret) == secret)
        #expect(newDeviceSecret() != newDeviceSecret())
    }

    /// The app restored its own session after a relaunch and signs out before identify():
    /// the device is still detached from the user who registered it.
    @Test func aLogoutAfterARelaunchDetachesByTheDeviceSecret() async throws {
        let app = TestApp()
        var kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        let put = try #require(registrations(app).first)
        kirora.destroy()

        kirora = app.start(push: .enabled)
        await kirora.logout()
        let delete = try #require(deletes(app).first)
        #expect(delete.path == put.path)
        #expect(delete.headers["Authorization"] == "Device \(put.deviceSecret ?? "")")
        #expect(delete.query["lastSeenAt"] == "2026-11-13T10:00:00.000Z")
        #expect(kirora.push.pendingDetachments == 0)
        // Detached: nothing more to do at the next sign-out. The secret stays the
        // installation's.
        await kirora.logout()
        #expect(deletes(app).count == 1)
        #expect(app.stored(StorageKeys.deviceSecret) == put.deviceSecret)
    }

    /// A detachment still pending as the app ends is tried again at the next launch.
    @Test func aPendingDetachmentIsResumedAfterARestart() async throws {
        let app = TestApp()
        let offline = Locked(true)
        app.server.answer { $0.method == "DELETE" && offline.current ? .networkError : nil }
        var kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        let secret = try #require(registrations(app).first?.deviceSecret)
        await kirora.logout()
        #expect(kirora.push.pendingDetachments == 1)
        kirora.destroy()

        offline.withLock { $0 = false }
        kirora = app.start(push: .enabled)
        #expect(await eventually { deletes(app).contains { $0.headers["Authorization"] == "Device \(secret)" } })
        #expect(await eventually { kirora.push.pendingDetachments == 0 && !kirora.push.registered })
    }

    /// One refused for good isn't resumed at the next launch.
    @Test func aRefusedDetachmentIsNotResumed() async throws {
        let app = TestApp()
        app.server.answer { $0.method == "DELETE" ? .error(403, "FORBIDDEN") : nil }
        var kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        let sent = deletes(app).count
        kirora.destroy()
        kirora = app.start(push: .enabled)
        await settle(0.3)
        #expect(deletes(app).count == sent)
    }

    /// The user's token, captured at sign-out, expires while the detachment is retried: the
    /// device secret carries on, rather than leaving the device attached.
    @Test func aRefusedTokenFallsBackToTheDeviceSecret() async throws {
        let app = TestApp()
        app.server.answer { request in
            request.method == "DELETE" && request.headers["Authorization"]?.hasPrefix("Bearer ") == true
                ? .error(401, "UNAUTHORIZED") : nil
        }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        let secret = try #require(registrations(app).first?.deviceSecret)
        await kirora.logout()
        #expect(deletes(app).map { $0.headers["Authorization"] ?? "" } == ["Bearer \(userToken("A"))", "Device \(secret)"])
        #expect(kirora.push.pendingDetachments == 0)
        #expect(!kirora.push.registered)
    }

    /// A token already refused, with no `fetchUserToken`, isn't sent again: the detachment
    /// goes by the secret straight away.
    @Test func aLogoutAfterARefusedTokenDetachesByTheSecretAlone() async throws {
        let app = TestApp()
        app.server.answer { $0.path.hasSuffix("/events/batch") ? .error(401, "UNAUTHORIZED") : nil }
        let kirora = app.start(push: .enabled, trackSessions: false)
        try await kirora.identify(userToken("A"))
        let secret = try #require(registrations(app).first?.deviceSecret)
        kirora.track("One")
        await kirora.flush()
        await kirora.logout()
        #expect(deletes(app).map { $0.headers["Authorization"] ?? "" } == ["Device \(secret)"])
        #expect(kirora.push.pendingDetachments == 0)
        #expect(!kirora.push.registered)
    }

    /// With a user signed in, their token goes, as before.
    @Test func aSignedInLogoutStillUsesTheUsersToken() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        #expect(deletes(app).map { $0.headers["Authorization"] ?? "" } == ["Bearer \(userToken("A"))"])
    }
}
