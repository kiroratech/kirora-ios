import Foundation
import Testing
@_spi(Wrapper) @testable import Kirora

// What the React Native and Flutter SDKs need from this one (`sdk-interface.md`, "Wrapper
// SDKs").

@Suite("Wrapper SDKs")
struct WrapperTests {
    @Test func aWrapperNamesItselfInKiroraSDK() async throws {
        #expect(sdkHeaderValue(name: "kirora-react-native", version: "1.2.0") == "kirora-react-native/1.2.0")
        #expect(sdkHeaderValue(name: "kirora-flutter", version: "0.3.1") == "kirora-flutter/0.3.1")
        #expect(sdkHeaderValue(name: "kirora-flutter", version: "1.0.0-rc.1+build.7") != nil)
        #expect(sdkHeaderValue(name: "kirora-flutter", version: String(repeating: "1", count: 40)) != nil)
        // Only what Kirora accepts (`<sdk>/[0-9A-Za-z.+-]{1,40}`): anything else would make it
        // refuse every call, and every event would wait unsent.
        for (name, version) in [("react-native", "1.0.0"), ("kirora-", "1.0.0"), ("Kirora-RN", "1.0.0"),
                                ("kirora-unity", "1.0.0"), ("kirora-flutter", ""), ("kirora-flutter", "1/2"),
                                ("kirora-flutter", "1 0"), ("kirora-flutter", "1.0.0_rc1"), ("kirora-flutter", "1.0.0é"),
                                ("kirora-flutter", String(repeating: "1", count: 41))] {
            #expect(sdkHeaderValue(name: name, version: version) == nil)
        }
        // This SDK's own version passes the same rule.
        #expect(isValidVersion(sdkVersion))
        // A client sends the name it was created with.
        let server = FakeKirora()
        let identity = Identity(fetchUserToken: nil)
        try await identity.signIn(token: userToken("u")) {}
        let api = ClientAPI(
            clientKey: "kirora_pk_test", apiUrl: "https://api.test.kirora.io", identity: identity,
            transport: server, sdk: "kirora-flutter/0.3.1"
        )
        try await api.request("PUT", "/push-consent", body: JSONValue.object(["granted": .bool(true)]))
        #expect(server.requests.first?.headers["Kirora-SDK"] == "kirora-flutter/0.3.1")
    }

    @Test func aTokenAnsweredAcrossTheBridgeSignsIn() async throws {
        let app = TestApp()
        let requests = Locked<[String]>([])
        let bridge = KiroraWrapper.TokenRequests { id in requests.withLock { $0.append(id) } }
        let kirora = app.start(fetchUserToken: { try await bridge.fetchUserToken() }, trackSessions: false)
        let signIn = Task { try await kirora.identify() }
        #expect(await eventually { requests.current.count == 1 })
        bridge.answer(requests.current[0], token: userToken("u"))
        try await signIn.value
        kirora.track("Signed in")
        await kirora.flush()
        #expect(app.server.batches.first.map { subjectOf($0.token ?? "") } == "u")
    }

    @Test func aBridgeFailureIsAUserTokenError() async throws {
        let app = TestApp()
        let bridge = KiroraWrapper.TokenRequests { _ in }
        let requests = Locked<[String]>([])
        let failing = KiroraWrapper.TokenRequests { id in
            requests.withLock { $0.append(id) }
            Task { bridge.answer("unrelated", token: "x") }
        }
        let kirora = app.start(fetchUserToken: { try await failing.fetchUserToken() })
        let signIn = Task { try await kirora.identify() }
        #expect(await eventually { requests.current.count == 1 })
        failing.fail(requests.current[0], message: "no session")
        await #expect(throws: UserTokenError.self) { try await signIn.value }
    }

    @Test func aLateAnswerIsDiscarded() async throws {
        let app = TestApp()
        let requests = Locked<[String]>([])
        let bridge = KiroraWrapper.TokenRequests { id in requests.withLock { $0.append(id) } }
        // The SDK's 30-second limit, shortened: the round trip as a whole.
        let kirora = app.start(fetchUserToken: { try await bridge.fetchUserToken() }, tokenTimeout: 0.1)
        await #expect(throws: UserTokenError.self) { try await kirora.identify() }
        let late = try #require(requests.current.first)
        #expect(!bridge.isPending(late))
        bridge.answer(late, token: userToken("u"))
        kirora.track("After")
        await kirora.flush()
        #expect(app.server.batches.isEmpty)
    }

    @Test func theBridgeHasItsOwnLimit() async throws {
        let bridge = KiroraWrapper.TokenRequests(timeout: 0.1) { _ in }
        await #expect(throws: WrapperError.self) { try await bridge.fetchUserToken() }
    }

    @Test func tapsBeforeTheListenerAreHeldTheLatestTen() {
        let events = PushTapEvents()
        for index in 0..<12 {
            events.deliver(KiroraPushTap(data: ["n": index], buttonIndex: nil, actionIdentifier: "default", link: nil))
        }
        let heard = Locked<[Int]>([])
        events.setListener { tap in heard.withLock { $0.append(tap.data["n"] as! Int) } }
        #expect(heard.current == Array(2..<12))
        events.deliver(KiroraPushTap(data: ["n": 12], buttonIndex: nil, actionIdentifier: "default", link: nil))
        #expect(heard.current.last == 12)
        events.setListener(nil)
        events.deliver(KiroraPushTap(data: ["n": 13], buttonIndex: nil, actionIdentifier: "default", link: nil))
        #expect(heard.current.count == 11)
    }

    @Test func anAppListenerHearsTapsOnTheMainThreadHeldOnesFirst() async {
        let events = PushTapEvents()
        events.deliver(KiroraPushTap(data: ["n": 1], buttonIndex: nil, actionIdentifier: "default", link: nil))
        events.deliver(KiroraPushTap(data: ["n": 2], buttonIndex: 0, actionIdentifier: "0", link: URL(string: "myapp://a")))
        let heard = Locked<[Int]>([])
        let id = events.addAppListener { tap in heard.withLock { $0.append(tap.data["n"] as! Int) } }
        #expect(heard.current == [1, 2])
        events.deliver(KiroraPushTap(data: ["n": 3], buttonIndex: nil, actionIdentifier: "default", link: nil))
        #expect(heard.current == [1, 2, 3])
        events.removeAppListener(id)
        events.deliver(KiroraPushTap(data: ["n": 4], buttonIndex: nil, actionIdentifier: "default", link: nil))
        #expect(heard.current == [1, 2, 3])
    }

    /// A wrapper detached (a Flutter engine torn down) holds taps again, even while the app
    /// listens natively: the engine that attaches next hears them.
    @Test func aDetachedWrapperHoldsTapsWhateverTheAppListensTo() {
        let events = PushTapEvents()
        let app = Locked<[Int]>([])
        _ = events.addAppListener { tap in app.withLock { $0.append(tap.data["n"] as! Int) } }
        let wrapper = Locked<[Int]>([])
        events.setListener { tap in wrapper.withLock { $0.append(tap.data["n"] as! Int) } }
        events.deliver(KiroraPushTap(data: ["n": 1], buttonIndex: nil, actionIdentifier: "default", link: nil))
        events.setListener(nil)
        events.deliver(KiroraPushTap(data: ["n": 2], buttonIndex: nil, actionIdentifier: "default", link: nil))
        #expect(app.current == [1, 2])
        #expect(wrapper.current == [1])
        events.setListener { tap in wrapper.withLock { $0.append(tap.data["n"] as! Int) } }
        #expect(wrapper.current == [1, 2])
    }

    @Test func thePublicListenerHearsTapsInOrder() async {
        let heard = Locked<[String]>([])
        let prefix = "order-\(UUID().uuidString)-"
        let registration = Kirora.addNotificationClickListener { tap in
            guard tap.actionIdentifier.hasPrefix(prefix) else { return }
            heard.withLock { $0.append(tap.actionIdentifier) }
        }
        for index in 0..<50 {
            pushTapEvents.deliver(KiroraPushTap(data: [:], buttonIndex: nil, actionIdentifier: "\(prefix)\(index)", link: nil))
        }
        #expect(await eventually { heard.current.count == 50 })
        #expect(heard.current == (0..<50).map { "\(prefix)\($0)" })
        registration.remove()
    }

    @Test func aRemovedListenerHearsNothingStillQueued() async {
        let heard = Locked(0)
        let prefix = "removed-\(UUID().uuidString)-"
        let registration = Kirora.addNotificationClickListener { tap in
            if tap.actionIdentifier.hasPrefix(prefix) { heard.withLock { $0 += 1 } }
        }
        // Queued while the main actor is busy, then removed before it gets to them.
        await MainActor.run {
            for index in 0..<5 {
                pushTapEvents.deliver(KiroraPushTap(data: [:], buttonIndex: nil, actionIdentifier: "\(prefix)\(index)", link: nil))
            }
            registration.remove()
        }
        await settle()
        #expect(heard.current == 0)
    }

    @Test func thePublicListenerIsCalledOnTheMainActor() async {
        let heard = Locked<[String]>([])
        let registration = Kirora.addNotificationClickListener { tap in
            MainActor.assertIsolated()
            heard.withLock { $0.append(tap.actionIdentifier) }
        }
        let id = "public-\(UUID().uuidString)"
        pushTapEvents.deliver(KiroraPushTap(data: [:], buttonIndex: nil, actionIdentifier: id, link: nil))
        #expect(await eventually { heard.current.contains(id) })
        registration.remove()
        registration.remove()
    }

    @Test func aTapIsReportedBeforeTheWrapperHearsIt() async throws {
        let server = FakeKirora()
        let order = Locked<[String]>([])
        server.answer { _ in order.withLock { $0.append("reported") }; return nil }
        let handler = PushTapHandler(transport: server, apiBase: { testApiBase }, openURL: { _ in order.withLock { $0.append("opened") } })
        let payload = KiroraPushPayload(userInfo: [
            "kirora": "true", "trackingUrl": "https://api.test.kirora.io/t/p/abc", "actionUrl": "myapp://orders/1",
        ])!
        await handler.handle(payload, action: .open) { link in
            order.withLock { $0.append("heard \(link?.absoluteString ?? "")") }
        }
        let reported = try #require(order.current.firstIndex(of: "reported"))
        let heard = try #require(order.current.firstIndex(of: "heard myapp://orders/1"))
        #expect(reported < heard)
    }

    @Test func aSlowReportHoldsTheTapEventNoMoreThanItsLimit() async {
        let server = FakeKirora()
        server.answer { _ in FakeAnswer(status: 204, body: nil, delay: 3) }
        let handler = PushTapHandler(transport: server, apiBase: { testApiBase }, openURL: { _ in })
        let payload = KiroraPushPayload(userInfo: ["kirora": "true", "trackingUrl": "https://api.test.kirora.io/t/p/abc"])!
        let heardAt = Locked<Date?>(nil)
        let started = Date()
        let handling = Task { await handler.handle(payload, action: .open) { _ in heardAt.withLock { $0 = Date() } } }
        #expect(await eventually(3) { heardAt.current != nil })
        #expect(heardAt.current!.timeIntervalSince(started) < 2.5)
        handling.cancel()
    }

    @Test func aPushsDataGoesToTheWrapperAsJSON() {
        let data = wrapperData([
            "kirora": "true", "trackingUrl": "https://t", "orderId": "42", "aps": ["alert": "Hi"], 7: "not a string key",
        ])
        #expect(data["orderId"] as? String == "42")
        #expect((data["aps"] as? [String: Any])?["alert"] as? String == "Hi")
        #expect(data.count == 4)
    }
}

@Suite("Wrapper callbacks", .serialized)
struct WrapperCallbackTests {
    @Test func aDeepLinkAnswerWaitsAtMostItsLimit() async {
        defer { KiroraWrapper.setDeepLinkHandler(nil) }
        let url = URL(string: "myapp://orders/1")!
        #expect(await wrapperOpenedLink(url) == false)
        KiroraWrapper.setDeepLinkHandler { _ in true }
        #expect(await wrapperOpenedLink(url))
        KiroraWrapper.setDeepLinkHandler { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        }
        let started = Date()
        #expect(await wrapperOpenedLink(url, timeout: 0.1) == false)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func aForegroundAnswerDefaultsToShowing() async {
        defer { KiroraWrapper.setForegroundPresentationHandler(nil) }
        #expect(await wrapperShowsInForeground(["kirora": "true"]))
        KiroraWrapper.setForegroundPresentationHandler { _ in false }
        #expect(await wrapperShowsInForeground(["kirora": "true"]) == false)
        KiroraWrapper.setForegroundPresentationHandler { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return false
        }
        #expect(await wrapperShowsInForeground(["kirora": "true"], timeout: 0.1))
    }
}

@Suite("Distribution")
struct DistributionTests {
    @Test func aLaunchLinkWaitsForTheWrappersHandler() async {
        // A native app's links don't wait.
        let native = LaunchLinks()
        #expect(await native.proceed(limit: 30))

        let links = LaunchLinks()
        links.arm()
        let opened = Locked<Bool?>(nil)
        let waiting = Task {
            let go = await links.proceed(limit: 30)
            opened.withLock { $0 = go }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(opened.current == nil)
        links.settle()
        await waiting.value
        #expect(opened.current == true)
        // Once the handler is set up, later links go at once.
        #expect(await links.proceed(limit: 30))
    }

    @Test func aLinkWaitsAgainOnceTheWrapperIsDetached() async {
        let links = LaunchLinks()
        links.arm()
        links.settle()
        #expect(await links.proceed(limit: 30))
        links.unsettle()
        let went = Locked(false)
        let waiting = Task {
            let go = await links.proceed(limit: 30)
            went.withLock { $0 = true }
            return go
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!went.current)
        links.settle()
        #expect(await waiting.value)
        // A native app's links never wait, detached or not.
        let native = LaunchLinks()
        native.unsettle()
        #expect(await native.proceed(limit: 30))
    }

    @Test func aLaterLaunchLinkTakesTheWaitingOnesPlace() async {
        let links = LaunchLinks()
        links.arm()
        let first = Task { await links.proceed(limit: 30) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let second = Task { await links.proceed(limit: 30) }
        #expect(await first.value == false)
        links.settle()
        #expect(await second.value == true)
    }

    @Test func aLaunchLinkOpensAnywayIfTheWrapperNeverSetsUp() async {
        let links = LaunchLinks()
        links.arm()
        let started = Date()
        #expect(await links.proceed(limit: 0.2))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func podspecVersionsMatchTheSDK() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Kirora.podspec", "KiroraNotificationService.podspec"] {
            let spec = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(spec.contains("s.version          = '\(sdkVersion)'"), "\(name)")
        }
    }

    /// The wrapper SDKs compile a copy of `Sources/Kirora` into one module, which can't
    /// hold two files of the same name.
    @Test func sourceFileNamesAreUnique() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Kirora")
        let names = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { ($0 as NSString).lastPathComponent }
        #expect(!names.isEmpty)
        #expect(Set(names).count == names.count, "\(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
    }
}
