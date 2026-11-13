import Foundation
import Testing
@testable import Kirora
@testable import KiroraNotificationService

private let devicePrefix = "/client/v1/devices/"

private let firebasePushApp: @Sendable (SentRequest) -> FakeAnswer? = { request in
    request.path.hasSuffix("/push-app")
        ? .ok(.object([
            "pushAppId": .string(FakeKirora.pushAppId), "name": .string("iOS via Firebase"),
            "targetKind": .string("fcm_token"), "vapidPublicKey": .null,
        ]))
        : nil
}

@Suite("Push registration")
struct PushRegistrationTests {
    @Test func registersTheAPNsTokenWithTheFourDeviceFields() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        let pushApp = try #require(app.server.requests("GET", "/client/v1/push-app").first)
        #expect(pushApp.query == ["platform": "ios"])
        let put = try #require(app.server.requests.first { $0.method == "PUT" && $0.path.hasPrefix(devicePrefix) })
        #expect(put.path == devicePrefix + app.store.string(StorageKeys.deviceId)!)
        #expect(put.body == .object([
            "pushAppId": .string(FakeKirora.pushAppId), "targetKind": .string("apns_token"),
            "permission": .string("granted"), "target": .string("abcd01"),
            "appVersion": .string("2.4.0"), "osVersion": .string("17.4.1"),
            "locale": .string("en-GB"), "timezone": .string("Africa/Lagos"),
        ]))
    }

    @Test func leavesOutWhatTheDeviceCantRead() async throws {
        let app = TestApp()
        app.deviceInfo.appVersion = { nil }
        app.deviceInfo.locale = { "" }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        let put = try #require(app.server.requests.first { $0.method == "PUT" })
        #expect(put.body?["appVersion"] == nil)
        #expect(put.body?["locale"] == nil)
        #expect(put.body?["osVersion"] == .string("17.4.1"))
    }

    @Test func namesThePushAppTheAppChose() async throws {
        let app = TestApp()
        let kirora = app.start(push: PushOptions(pushAppId: "9b2e0a2c-0000-4000-8000-000000000001"))
        try await kirora.identify(userToken("user-1"))
        #expect(app.server.requests("GET", "/client/v1/push-app").first?.query["pushAppId"] == "9b2e0a2c-0000-4000-8000-000000000001")
    }

    @Test func aSignedInStartCostsNoPushCallsTheSameDay() async throws {
        let app = TestApp()
        try await app.start(push: .enabled).identify(userToken("user-1"))
        try await app.start(push: .enabled).identify(userToken("user-1"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 1)
        // A day later, it registers again.
        app.clock.advance(25 * 60 * 60)
        try await app.start(push: .enabled).identify(userToken("user-1"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 2)
    }

    @Test func registersAgainForANewUserOrToken() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        try await kirora.identify(userToken("user-2"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 2)
        app.push.apnsToken.withLock { $0 = Data([0x01, 0x02]) }
        app.tokens.received(Data([0x01, 0x02]))
        #expect(await eventually { app.server.requests.filter { $0.method == "PUT" }.last?.body?["target"] == .string("0102") })
    }

    @Test func doesNothingWithoutPermissionOrWhenPushIsOff() async throws {
        let app = TestApp()
        app.push.status.withLock { $0 = .notDetermined }
        try await app.start(push: .enabled).identify(userToken("user-1"))
        try await app.start().identify(userToken("user-1"))
        await settle()
        #expect(app.server.requests.filter { $0.path.hasPrefix(devicePrefix) || $0.path.hasSuffix("push-app") }.isEmpty)
    }

    @Test func aFailingRegistrationNeverFailsIdentify() async throws {
        let app = TestApp()
        app.server.answer { $0.method == "PUT" ? .error(500, "INTERNAL") : nil }
        try await app.start(push: .enabled).identify(userToken("user-1"))
    }

    @Test func reportsNotificationsTurnedOffInSettings() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        app.push.status.withLock { $0 = .denied }
        app.lifecycle.fire(.foreground)
        #expect(await eventually { app.server.requests.filter { $0.method == "PUT" }.count == 2 })
        let denial = try #require(app.server.requests.filter { $0.method == "PUT" }.last)
        #expect(denial.body?["permission"] == .string("denied"))
        #expect(denial.body?["lastSeenAt"] == .string("2026-11-13T10:00:00.000Z"))
        #expect(denial.body?["pushAppId"] == .string(FakeKirora.pushAppId))
        #expect(denial.body?["target"] == nil)
    }

    @Test func requestPushPermissionAnswersAsEverySDKDoes() async throws {
        let app = TestApp()
        #expect(await app.start().requestPushPermission() == .unsupported)
        app.push.status.withLock { $0 = .notDetermined }
        app.push.promptAnswer.withLock { $0 = .notDetermined }
        #expect(await app.start(push: .enabled).requestPushPermission() == .unanswered)
        app.push.promptAnswer.withLock { $0 = .denied }
        #expect(await app.start(push: .enabled).requestPushPermission() == .denied)
        app.push.promptAnswer.withLock { $0 = .authorized }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        #expect(await kirora.requestPushPermission() == .granted)
    }

    @Test func logoutDetachesTheDevice() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        await kirora.logout()
        let delete = try #require(app.server.requests.first { $0.method == "DELETE" })
        #expect(delete.path == devicePrefix + app.store.string(StorageKeys.deviceId)!)
        #expect(delete.token == userToken("user-1"))
    }

    @Test func aDetachKiroraCantTakeIsRetriedInTheBackground() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        let failures = Locked(2)
        app.server.answer { request in
            guard request.method == "DELETE" else { return nil }
            return failures.withLock { left in
                defer { left -= 1 }
                return left > 0 ? FakeAnswer.networkError : nil
            }
        }
        await kirora.logout()
        #expect(await eventually { app.server.requests.filter { $0.method == "DELETE" }.count == 3 })
        #expect(app.server.requests.filter { $0.method == "DELETE" }.allSatisfy { $0.token == userToken("user-1") })
        await settle(0.3)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == 3)
    }

    @Test func logoutWaitsAtMostItsLimitThenForgetsTheUser() async throws {
        let app = TestApp()
        app.logoutWait = 0.2
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        app.server.answer { $0.method == "DELETE" ? FakeAnswer(status: 204, body: nil, delay: 2) : nil }
        let started = Date()
        await kirora.logout()
        #expect(Date().timeIntervalSince(started) < 1)
        // Forgotten: nothing more goes as user-1.
        kirora.track("After Logout")
        await kirora.flush()
        await settle()
        #expect(!app.server.sentEventNames.contains("After Logout"))
        // The detachment carried on in the background.
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == 1)
    }

    @Test func logoutsDeadlineIncludesASignInStillWaitingForItsToken() async throws {
        let app = TestApp()
        app.logoutWait = 0.2
        let asked = Locked(false)
        let kirora = app.start(fetchUserToken: {
            asked.withLock { $0 = true }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return userToken("late")
        })
        try await kirora.identify(userToken("user-1"))
        let pending = Task { try? await kirora.identify() }
        #expect(await eventually { asked.current })
        let started = Date()
        await kirora.logout()
        #expect(Date().timeIntervalSince(started) < 0.6)
        // The late token signs no one in.
        await pending.value
        kirora.track("After Logout")
        await kirora.flush()
        await settle()
        #expect(!app.server.sentEventNames.contains("After Logout"))
    }

    @Test func aDestroyStopsTheDetachRetries() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        app.server.answer { $0.method == "DELETE" ? .networkError : nil }
        await kirora.logout()
        kirora.destroy()
        let deletes = app.server.requests.filter { $0.method == "DELETE" }.count
        await settle(0.4)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == deletes)
    }

    @Test func aDestroyDuringTheFirstDetachStopsRetriesToo() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        app.server.answer { $0.method == "DELETE" ? FakeAnswer(status: 0, body: nil, offline: true, delay: 0.15) : nil }
        let logout = Task { await kirora.logout() }
        #expect(await eventually { !app.server.requests.filter { $0.method == "DELETE" }.isEmpty })
        kirora.destroy()
        await logout.value
        await settle(0.4)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == 1)
    }

    @Test func aSignInStopsTheDetachRetries() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        app.server.answer { $0.method == "DELETE" ? .networkError : nil }
        await kirora.logout()
        try await kirora.identify(userToken("user-2"))
        let deletes = app.server.requests.filter { $0.method == "DELETE" }.count
        await settle(0.4)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == deletes)
    }

    @Test func logoutDetachesOnlyTheUsersOwnRegistration() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        // user-2 signs in without user-1 logging out, and can't be registered.
        app.push.status.withLock { $0 = .notDetermined }
        try await kirora.identify(userToken("user-2"))
        await kirora.logout()
        #expect(app.server.requests.filter { $0.method == "DELETE" }.isEmpty)
    }

    @Test func aNewUserWithNotificationsOffTakesTheDeviceOver() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        app.push.status.withLock { $0 = .denied }
        try await kirora.identify(userToken("user-2"))
        let denial = try #require(app.server.requests.filter { $0.method == "PUT" }.last)
        #expect(denial.token == userToken("user-2"))
        #expect(denial.body?["permission"] == .string("denied"))
        // Reported once.
        try await kirora.identify(userToken("user-2"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.count == 2)
    }

    @Test func registersFirebasesTokenForAPushAppThatSendsThroughFirebase() async throws {
        let app = TestApp()
        app.server.answer(firebasePushApp)
        app.push.fcmToken.withLock { $0 = "fcm-token-1" }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("user-1"))
        let put = try #require(app.server.requests.first { $0.method == "PUT" })
        #expect(put.body?["targetKind"] == .string("fcm_token"))
        #expect(put.body?["target"] == .string("fcm-token-1"))
        // The next start costs no push calls, and a new Firebase token registers again.
        try await app.start(push: .enabled).identify(userToken("user-1"))
        #expect(app.server.requests("GET", "/client/v1/push-app").count == 1)
        app.push.fcmToken.withLock { $0 = "fcm-token-2" }
        app.tokens.firebaseTokenChanged()
        #expect(await eventually { app.server.requests.filter { $0.method == "PUT" }.last?.body?["target"] == .string("fcm-token-2") })
    }

    @Test func registersNothingForAFirebasePushAppWithoutFirebase() async throws {
        let app = TestApp()
        app.server.answer(firebasePushApp)
        try await app.start(push: .enabled).identify(userToken("user-1"))
        #expect(app.server.requests.filter { $0.method == "PUT" }.isEmpty)
    }

    @Test func anOlderServerWithoutTargetKindMeansAPNs() async throws {
        let app = TestApp()
        app.server.answer { request in
            request.path.hasSuffix("/push-app")
                ? .ok(.object(["pushAppId": .string(FakeKirora.pushAppId), "name": .string("iOS"), "vapidPublicKey": .null]))
                : nil
        }
        try await app.start(push: .enabled).identify(userToken("user-1"))
        #expect(app.server.requests.first { $0.method == "PUT" }?.body?["targetKind"] == .string("apns_token"))
    }

    @Test func pushConsentIsRecordedAsTheUser() async throws {
        let app = TestApp()
        let kirora = app.start()
        try await kirora.identify(userToken("user-1"))
        try await kirora.setPushConsent(true)
        let put = try #require(app.server.requests("PUT", "/client/v1/push-consent").first)
        #expect(put.body == .object(["granted": .bool(true)]))
    }
}

@Suite("App opens")
struct AppOpenTests {
    private func appOpens(_ app: TestApp) -> [SentRequest] {
        app.server.requests.filter { $0.path.hasSuffix("/app-opens") }
    }

    @Test func goOnceAtLaunchForASignedInRegisteredDevice() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("user-1"))
        #expect(await eventually { appOpens(app).count == 1 })
        let open = appOpens(app)[0]
        #expect(open.body == .object(["occurredAt": .string(isoTimestamp(app.clock.now)), "pushAppId": .string(FakeKirora.pushAppId)]))
        #expect(open.path == devicePrefix + app.store.string(StorageKeys.deviceId)! + "/app-opens")
    }

    @Test func goAgainOnlyAfter30Minutes() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("user-1"))
        #expect(await eventually { appOpens(app).count == 1 })
        app.lifecycle.fire(.background)
        app.clock.advance(10 * 60)
        app.lifecycle.fire(.foreground)
        await settle()
        #expect(appOpens(app).count == 1)
        app.lifecycle.fire(.background)
        app.clock.advance(31 * 60)
        app.lifecycle.fire(.foreground)
        #expect(await eventually { appOpens(app).count == 2 })
    }

    @Test func neverWhileSignedOutOrUnregistered() async throws {
        let app = TestApp()
        // Signed out.
        app.start(push: .enabled)
        app.lifecycle.fire(.launched)
        await settle()
        // Signed in, but push off: never registered.
        let kirora = app.start()
        app.clock.advance(31 * 60)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("user-1"))
        await settle()
        #expect(appOpens(app).isEmpty)
    }

    @Test func waitWhileOffline() async throws {
        let app = TestApp()
        app.server.answer { $0.path.hasSuffix("/app-opens") ? .networkError : nil }
        let kirora = app.start(push: .enabled)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("user-1"))
        #expect(await eventually { appOpens(app).count == 1 })
        app.server.answer { _ in nil }
        #expect(await eventually { appOpens(app).count == 2 })
        let opens = appOpens(app)
        #expect(opens.count == 2 && opens[0].body == opens[1].body)
        await settle(0.3)
        #expect(appOpens(app).count == 2)
    }

    @Test func areDroppedOnA404OrA400() async throws {
        for status in [404, 400] {
            let app = TestApp()
            app.server.answer { $0.path.hasSuffix("/app-opens") ? .error(status, "NOT_FOUND") : nil }
            let kirora = app.start(push: .enabled)
            app.lifecycle.fire(.launched)
            try await kirora.identify(userToken("user-1"))
            #expect(await eventually { appOpens(app).count == 1 })
            await settle(0.3)
            #expect(appOpens(app).count == 1)
        }
    }

    @Test func areNotEvents() async throws {
        let app = TestApp()
        let kirora = app.start(push: .enabled, trackSessions: false)
        app.lifecycle.fire(.launched)
        try await kirora.identify(userToken("user-1"))
        #expect(await eventually { appOpens(app).count == 1 })
        await kirora.flush()
        #expect(app.server.sentEventNames.isEmpty)
    }
}

@Suite("Push taps and deliveries")
struct PushReportTests {
    @Test func aTapOnTheNotificationOpensItsLinkAndReportsAClick() async {
        let server = FakeKirora()
        let opened = Locked<[URL]>([])
        let handler = PushTapHandler(transport: server, openURL: { url in opened.withLock { $0.append(url) } })
        let payload = KiroraPushPayload(userInfo: [
            "aps": ["alert": "Hi"], "trackingUrl": "https://api.test.kirora.io/t/p/abc", "actionUrl": "myapp://orders/1",
        ])!
        await handler.handle(payload, action: .open)
        #expect(opened.current == [URL(string: "myapp://orders/1")!])
        #expect(server.requests.map(\.path) == ["/t/p/abc"])
        #expect(server.requests.first?.body == .object(["event": .string("clicked")]))
    }

    @Test func aTapWithoutALinkIsAnOpen() async {
        let server = FakeKirora()
        let handler = PushTapHandler(transport: server, openURL: { _ in })
        await handler.handle(KiroraPushPayload(userInfo: ["trackingUrl": "https://api.test.kirora.io/t/p/abc"])!, action: .open)
        #expect(server.requests.first?.body == .object(["event": .string("opened")]))
    }

    @Test func aPushWithoutTrackingUrlReportsNothing() async {
        let server = FakeKirora()
        let handler = PushTapHandler(transport: server, openURL: { _ in })
        await handler.handle(KiroraPushPayload(userInfo: ["kirora": "true", "actionUrl": "https://shop.example"])!, action: .open)
        #expect(server.requests.isEmpty)
        #expect(KiroraPushPayload(userInfo: ["aps": ["alert": "Someone else's"]]) == nil)
    }

    @Test func onlyAMarkedPushOrKirorasTrackingPathIsKiroras() {
        // Another provider's push using the same generic names.
        #expect(KiroraPushPayload(userInfo: ["actionUrl": "https://other.example/promo"]) == nil)
        #expect(KiroraPushPayload(userInfo: ["trackingUrl": "https://other.example/track"]) == nil)
        #expect(KiroraPushPayload(userInfo: ["kirora": "true"]) != nil)
        #expect(KiroraPushPayload(userInfo: ["trackingUrl": "https://api.kirora.io/t/p/abc"]) != nil)
        // Links Kirora would never send aren't opened.
        let unsafe = KiroraPushPayload(userInfo: ["kirora": "true", "actionUrl": "javascript:alert(1)"])
        #expect(unsafe?.actionUrl == nil)
        #expect(KiroraNotificationService.kiroraPush(["imageUrl": "https://other.example/a.png"]) == nil)
        #expect(KiroraNotificationService.kiroraPush(["kirora": "true", "imageUrl": "http://cdn.example/a.png"])?.imageUrl == nil)
    }

    @Test func aFailedReportIsTriedOnceMore() async {
        let server = FakeKirora()
        server.answer { _ in .error(503, "UNAVAILABLE") }
        await TrackingReport.post("opened", to: URL(string: "https://api.test.kirora.io/t/p/abc")!, transport: server)
        #expect(server.requests.count == 2)
        let refused = FakeKirora()
        refused.answer { _ in .error(400, "VALIDATION_ERROR") }
        await TrackingReport.post("opened", to: URL(string: "https://api.test.kirora.io/t/p/abc")!, transport: refused)
        #expect(refused.requests.count == 1)
    }

    @Test func eachTapIsHandledOnce() {
        let id = UUID().uuidString
        #expect(firstTimeHandling(id))
        #expect(!firstTimeHandling(id))
    }
}

@Suite("Notification Service Extension", .serialized)
struct NotificationServiceTests {
    @Test func reportsDeliveredOnceAndRetriesOnce() async {
        StubProtocol.reset(statuses: [503, 204])
        await KiroraNotificationService.report(URL(string: "https://api.test.kirora.io/t/p/abc"), session: StubProtocol.session)
        #expect(StubProtocol.bodies.current == [#"{"event":"delivered"}"#, #"{"event":"delivered"}"#])
        StubProtocol.reset(statuses: [204])
        await KiroraNotificationService.report(URL(string: "https://api.test.kirora.io/t/p/abc"), session: StubProtocol.session)
        #expect(StubProtocol.bodies.current.count == 1)
    }

    @Test func aPushWithoutTrackingUrlReportsNothing() async {
        StubProtocol.reset(statuses: [204])
        await KiroraNotificationService.report(nil, session: StubProtocol.session)
        #expect(StubProtocol.bodies.current.isEmpty)
    }

    @Test func namesImagesByTheirType() {
        let url = URL(string: "https://cdn.example/image")!
        #expect(KiroraNotificationService.imageExtension(mimeType: "image/png", url: url) == "png")
        #expect(KiroraNotificationService.imageExtension(mimeType: nil, url: URL(string: "https://cdn.example/a.gif")!) == "gif")
        #expect(KiroraNotificationService.imageExtension(mimeType: "application/octet-stream", url: url) == "jpg")
    }
}

/// Answers URLSession requests with scripted statuses, recording their bodies.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let statuses = Locked<[Int]>([])
    static let bodies = Locked<[String]>([])
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static func reset(statuses: [Int]) {
        self.statuses.withLock { $0 = statuses }
        bodies.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self.bodies.withLock { $0.append(String(decoding: body ?? Data(), as: UTF8.self)) }
        let status = Self.statuses.withLock { $0.isEmpty ? 204 : $0.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
