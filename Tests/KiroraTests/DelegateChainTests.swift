import Foundation
import Testing
@testable import Kirora

/// A notification delegate: records being called, then passes the call on to the one it
/// found when it was set (the SDK's stand-in), if it keeps it, as `firebase_messaging` does.
private final class Delegate {
    let name: String
    let handles: Bool
    var passesBack: (() -> Void)?
    init(_ name: String, handles: Bool = true) { self.name = name; self.handles = handles }
}

/// The SDK's stand-in delegate, as `NotificationCenterProxy` passes calls on.
private final class StandIn {
    let chain = DelegateChain()
    var calls: [String] = []
    /// The delegates, kept alive as an app keeps its own: the chain holds them weakly.
    private var kept: [Delegate] = []

    func call() {
        let passed = chain.passOn(where: { ($0 as? Delegate)?.handles == true }) { delegate in
            let delegate = delegate as! Delegate
            calls.append(delegate.name)
            delegate.passesBack?()
        }
        if !passed { calls.append(chain.isPassingOn ? "left to the caller" : "no delegate") }
    }

    /// Sets `delegate` as the center's delegate; it keeps the stand-in, as it finds it there.
    func set(_ delegate: Delegate, keepsStandIn: Bool) {
        if keepsStandIn { delegate.passesBack = { [unowned self] in self.call() } }
        kept.append(delegate)
        chain.set(delegate)
    }
}

@Suite("Delegate chain")
struct DelegateChainTests {
    /// firebase_messaging, set up after the SDK, passes calls back to it: they go on to the
    /// app's delegate before it, and end, rather than looping until the stack overflows.
    @Test func aDelegateThatPassesBackReachesTheOneBeforeIt() {
        let standIn = StandIn()
        let app = Delegate("app")
        let firebase = Delegate("firebase")
        standIn.set(app, keepsStandIn: false)
        standIn.set(firebase, keepsStandIn: true)

        standIn.call()
        #expect(standIn.calls == ["firebase", "app"])
        #expect(!standIn.chain.isPassingOn)

        // The next call starts at the newest again.
        standIn.calls = []
        standIn.call()
        #expect(standIn.calls == ["firebase", "app"])
    }

    @Test func passedBackWithNoDelegateLeftItIsLeftToTheCaller() {
        let standIn = StandIn()
        let firebase = Delegate("firebase")
        standIn.set(firebase, keepsStandIn: true)
        standIn.call()
        #expect(standIn.calls == ["firebase", "left to the caller"])
    }

    @Test func everyDelegatePassingBackStillEnds() {
        let standIn = StandIn()
        let delegates = (1...3).map { Delegate("d\($0)") }
        for delegate in delegates { standIn.set(delegate, keepsStandIn: true) }
        standIn.call()
        #expect(standIn.calls == ["d3", "d2", "d1", "left to the caller"])
    }

    @Test func aDelegateThatReplacesWithoutPassingOnIsTheOnlyOneCalled() {
        let standIn = StandIn()
        let first = Delegate("first")
        let second = Delegate("second")
        standIn.set(first, keepsStandIn: false)
        standIn.set(second, keepsStandIn: false)
        standIn.call()
        #expect(standIn.calls == ["second"])
    }

    @Test func noDelegateAtAll() {
        let standIn = StandIn()
        standIn.call()
        #expect(standIn.calls == ["no delegate"])
    }

    @Test func settingTheSameDelegateAgainMakesItTheNewestOnce() {
        let standIn = StandIn()
        let app = Delegate("app")
        let firebase = Delegate("firebase")
        standIn.set(firebase, keepsStandIn: true)
        standIn.set(app, keepsStandIn: false)
        standIn.set(firebase, keepsStandIn: true)
        standIn.call()
        #expect(standIn.calls == ["firebase", "app"])
    }

    @Test func clearingTheDelegateForgetsThemAll() {
        let standIn = StandIn()
        let app = Delegate("app")
        standIn.set(app, keepsStandIn: false)
        standIn.chain.set(nil)
        standIn.call()
        #expect(standIn.calls == ["no delegate"])
    }

    @Test func delegatesThatDontHandleTheCallAreSkipped() {
        let standIn = StandIn()
        let app = Delegate("app")
        standIn.set(app, keepsStandIn: false)
        let silent = Delegate("silent", handles: false)
        standIn.set(silent, keepsStandIn: false)
        standIn.call()
        #expect(standIn.calls == ["app"])
        #expect(standIn.chain.contains { ($0 as? Delegate)?.handles == false })
    }

    @Test func aReleasedDelegateIsForgotten() {
        let standIn = StandIn()
        let app = Delegate("app")
        standIn.set(app, keepsStandIn: false)
        // Set without being kept: released at once.
        standIn.chain.set(Delegate("gone"))
        standIn.call()
        #expect(standIn.calls == ["app"])
    }
}
