import Foundation
import Testing
@testable import Kirora
@testable import KiroraNotificationService

/// Regressions for the audit of 22 November 2026.
@Suite("Audit fixes")
struct AuditTests {
    /// Two threads asking for the device id at once, on a fresh install, get the same one:
    /// events and the push registration never name different devices.
    @Test func aDeviceIdMadeOnManyThreadsAtOnceIsOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [KeyValueStore] = [
            MemoryKeyValueStore(),
            FileKeyValueStore(file: PersistentFile(url: directory.appendingPathComponent("state.json"), onError: { _ in })),
        ]
        for store in stores {
            let deviceId = DeviceId(store: store)
            let ids = Locked<Set<String>>([])
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let id = deviceId.value()
                ids.withLock { _ = $0.insert(id) }
            }
            #expect(ids.current.count == 1)
            #expect(ids.current.first == store.string(StorageKeys.deviceId))
        }
    }

    /// Tracking refused while the device is being registered: the id it's registered as is
    /// kept, so signing out detaches that device, not a new one.
    @Test func aTrackingRefusalDuringARegistrationKeepsItsDeviceId() async throws {
        let app = TestApp()
        app.server.answer { request in
            guard request.method == "PUT", request.path.hasPrefix("/client/v1/devices/") else { return nil }
            var answer = FakeKirora.defaultAnswer(request)
            answer.delay = 0.3
            return answer
        }
        let kirora = app.start(push: .enabled)
        let signIn = Task { try await kirora.identify(userToken("A")) }
        #expect(await eventually { !app.server.requests.filter { $0.method == "PUT" && $0.path.hasPrefix("/client/v1/devices/") }.isEmpty })
        kirora.setTrackingConsent(false)
        try await signIn.value
        let put = try #require(app.server.requests.filter { $0.method == "PUT" && $0.path.hasPrefix("/client/v1/devices/") }.first)
        let registeredId = String(put.path.dropFirst("/client/v1/devices/".count))
        #expect(app.stored(StorageKeys.deviceId) == registeredId)

        await kirora.logout()
        let delete = try #require(app.server.requests.filter { $0.method == "DELETE" }.first)
        #expect(delete.path == put.path)
    }

    /// Refused while the push app is still being looked up, before the device is registered:
    /// the id the registration's configuration names is the one it registers and keeps.
    @Test func aTrackingRefusalBeforeTheRegistrationsRequestKeepsItsDeviceId() async throws {
        let app = TestApp()
        app.server.answer { request in
            guard request.path == "/client/v1/push-app" else { return nil }
            var answer = FakeKirora.defaultAnswer(request)
            answer.delay = 0.3
            return answer
        }
        let kirora = app.start(push: .enabled)
        let signIn = Task { try await kirora.identify(userToken("A")) }
        #expect(await eventually { app.server.requests.contains { $0.path == "/client/v1/push-app" } })
        kirora.setTrackingConsent(false)
        try await signIn.value
        let put = try #require(app.server.requests.first { $0.method == "PUT" && $0.path.hasPrefix("/client/v1/devices/") })
        #expect(put.path == "/client/v1/devices/" + (app.stored(StorageKeys.deviceId) ?? ""))
        #expect(await kirora.getPushStatus() == .enabled)
    }

    /// Going to the background doesn't send a detachment Kirora asked to wait for.
    @Test func goingToTheBackgroundRespectsRetryAfterForADetachment() async throws {
        let app = TestApp()
        app.server.answer { $0.method == "DELETE" ? .error(429, "RATE_LIMITED", retryAfter: "3600") : nil }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        #expect(kirora.push.pendingDetachments == 1)
        let sent = app.server.requests.filter { $0.method == "DELETE" }.count
        app.lifecycle.fire(.background)
        app.lifecycle.fire(.foreground)
        await settle(0.3)
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == sent)
        #expect(kirora.push.pendingDetachments == 1)
    }

    /// A signed-out user's device still to detach is tried again as the app goes to the
    /// background, with time from iOS, rather than waiting for its backoff while suspended.
    @Test func goingToTheBackgroundRetriesADetachment() async throws {
        let app = TestApp()
        let offline = Locked(true)
        app.server.answer { $0.method == "DELETE" && offline.current ? .networkError : nil }
        let kirora = app.start(push: .enabled)
        try await kirora.identify(userToken("A"))
        await kirora.logout()
        #expect(kirora.push.pendingDetachments == 1)

        offline.withLock { $0 = false }
        let backgroundWork = app.lifecycle.backgroundWork.current
        app.lifecycle.fire(.background)
        #expect(app.lifecycle.backgroundWork.current > backgroundWork)
        #expect(await eventually { kirora.push.pendingDetachments == 0 })
        #expect(app.server.requests.filter { $0.method == "DELETE" }.count == 2)
    }

    /// State that can't be encoded leaves the file as it was: never removed as if empty.
    @Test func anEncodingFailureKeepsTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kirora-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let errors = Locked(0)
        let file = PersistentFile(url: url, onError: { _ in errors.withLock { $0 += 1 } })
        file.write { Data("saved".utf8) }
        file.waitForWrites()
        struct Unencodable: Error {}
        file.write { throw Unencodable() }
        file.waitForWrites()
        #expect(try Data(contentsOf: url) == Data("saved".utf8))
        #expect(errors.current == 1)
        // Not saved, and said so.
        #expect(file.writeFailed)
    }

    /// The notification extension holds a push back for its delivery report only so long.
    @Test func aSlowDeliveryReportDoesntHoldThePushBack() async {
        let slowReport = Task { _ = try? await Task.sleep(nanoseconds: 10_000_000_000) }
        defer { slowReport.cancel() }
        let start = Date()
        await KiroraNotificationService.wait(for: slowReport, upTo: 0.2)
        #expect(Date().timeIntervalSince(start) < 2)

        // One that finishes first ends the wait at once.
        let quickReport = Task {}
        let quickStart = Date()
        await KiroraNotificationService.wait(for: quickReport, upTo: 5)
        #expect(Date().timeIntervalSince(quickStart) < 2)
    }
}
