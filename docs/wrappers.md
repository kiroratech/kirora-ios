# Wrapping the iOS SDK (React Native, Flutter)

For the authors of Kirora's React Native and Flutter SDKs. On iOS they call this SDK, which
does the work: queue, sessions, consent, push, retries, sign-out. The wrapper's own language
only forwards calls and answers. The contract is "Wrapper SDKs" in `docs/sdk-interface.md` in
the omnichannel repo.

## Linking

React Native links native iOS code through CocoaPods; Flutter through CocoaPods or Swift
Package Manager, whichever the app uses, so a Flutter plugin ships both. In the wrapper's
podspec:

```ruby
s.dependency 'Kirora', '~> 0.1'
```

and in a Flutter plugin's `ios/<plugin>/Package.swift`, beside Flutter's own
`FlutterFramework` dependency:

```swift
.package(url: "https://github.com/kiroratech/kirora-ios.git", from: "0.1.0"),
// in the target: .product(name: "Kirora", package: "kirora-ios")
```

Swift Package Manager resolves versions from this repo's git tags, so a release must be
tagged before a wrapper's manifest can use it. Name a version range, and say in the wrapper's
release notes which native versions it was tested with. The app's Notification Service
Extension adds `KiroraNotificationService` itself (see the README's "Delivery reports and
images").

The wrapper surface is Swift SPI. The wrapper's native module, written in Swift, imports it:

```swift
@_spi(Wrapper) import Kirora
```

## At launch

The tap that launched the app reaches the SDK only if it's hooked into the app's push
callbacks when launching finishes, long before JavaScript or Dart creates the client. Call
`KiroraWrapper.installPushIntegration()` from the wrapper's native code at launch:

- **Flutter:** in the plugin's `register(with:)`, which `GeneratedPluginRegistrant` calls
  during `didFinishLaunching`.
- **React Native:** from an Objective-C `+load` in the module, calling the module's Swift
  (Swift can't define `+load`), so it works whatever the app's `AppDelegate` looks like.
  This is how React Native Firebase's messaging module hooks in.

It's safe before the app exists, more than once, and before creating the client. A tap it
hears before the client exists is reported to Kirora at once and held for the tap listener.
It does nothing if the app set `KiroraAppDelegateProxyEnabled` to `NO`; such an app forwards
the callbacks itself (see the README).

The link of that launch tap waits for the wrapper's first `setDeepLinkHandler` call, with a
handler or with `nil`, up to 10 seconds: opened at once, before JavaScript runs, React
Native's `Linking` would miss it. So call `setDeepLinkHandler` once the wrapper's language is
ready, even with `nil` when the app has no handler. Only the latest launch link waits; one
tapped while another waits takes its place.

## Setup, in order

```swift
// 1. Before creating the client: the wrapper's name in `Kirora-SDK`. Kirora refuses every
//    call whose version isn't 1 to 40 of 0-9 A-Z a-z . + - (so not `1.0.0_rc1`): such a
//    version is ignored and logged, and the SDK's own name sent.
KiroraWrapper.setSDK(name: "kirora-react-native", version: wrapperVersion)

// 2. Tokens answered from JavaScript or Dart.
let tokens = KiroraWrapper.TokenRequests { requestId in
    emit("kirora.fetchUserToken", ["requestId": requestId])
}

// 3. The client, with the app's options forwarded. No beforeSend: see below.
let kirora = Kirora(options: KiroraOptions(
    clientKey: clientKey,
    fetchUserToken: hasFetchUserToken ? { try await tokens.fetchUserToken() } : nil,
    // reason.rawValue is "fetch_failed" or "refused", the spec's names.
    onAuthenticationFailed: hasAuthenticationFailedHandler
        ? { reason in emit("kirora.authenticationFailed", ["reason": reason.rawValue]) } : nil,
    push: pushOptions,
    requireTrackingConsent: requireTrackingConsent,
    trackSessions: trackSessions,
    trackAppLifecycle: trackAppLifecycle,
    logLevel: logLevel,
    apiUrl: apiUrl
))

// 4. Callbacks the app answers, if it set them.
KiroraWrapper.setDeepLinkHandler { url in await askApp("handleDeepLink", url) }
KiroraWrapper.setForegroundPresentationHandler { data in await askApp("showInForeground", data) }

// 5. Taps, once the wrapper's language is listening.
KiroraWrapper.setTapListener { tap in emit("kirora.pushTapped", tap) }
```

From the wrapper's language, answer a token request with `tokens.answer(requestId, token:)`
or `tokens.fail(requestId, message:)`.

## What the SDK guarantees

- **Tokens.** The 30-second limit covers the whole round trip. A request unanswered by then
  fails as `UserTokenError`; an answer that comes later, or one for an earlier user's
  request, is discarded. Every request is answered once, so nothing waits for good.
- **Taps.** The SDK reports the tap to Kirora and opens its link before the listener hears
  it (it waits up to 1.5 seconds for the report). Taps before the listener is attached (one
  that launched the app) are held, the latest ten, and delivered in order when it is. A tap
  carries the push's data as JSON values, the button's position (nil for the notification
  itself), the action identifier, and the link opened.
- **Native listeners.** An app may also add `Kirora.addNotificationClickListener` in native
  code; both hear each tap. Each holds the taps it missed (the latest ten) until it has a
  listener, so a detached wrapper's next listener hears them whatever the app listens to.
- **Buttons.** A push's buttons come from the app's Notification Service Extension
  (`KiroraNotificationService`), which the wrapper doesn't create: its README says so.
- **Callbacks.** `handleDeepLink` and foreground display wait 1.5 seconds at most for the
  app's answer, then act as if there were no callback: the link is opened, the push shown.
  An app's own native `handleDeepLink`, or notification delegate implementing `willPresent`,
  decides first; a delegate that leaves a Kirora push unanswered for 1.5 seconds (as plugins
  such as `flutter_local_notifications` do with pushes they didn't schedule) has the SDK
  decide instead, so the wrapper's foreground handler is then asked.
- **Teardown.** When the wrapper's language goes away but the app doesn't (a Flutter
  engine torn down, a React Native bridge invalidated), call `KiroraWrapper.wrapperDetached()`,
  not `setDeepLinkHandler(nil)`: taps are held again and a tap's link waits for the next
  `setDeepLinkHandler`, as at launch. `nil` means "set up, with no handler": links open at once.
- **Launch links.** After `installPushIntegration()`, a tap's link heard before the first
  `setDeepLinkHandler` call waits for it (10 seconds at most), then goes the usual way. The
  tap listener hears that tap after its link has gone.
- **Methods.** Every method and option in the public interface is there to forward; nothing
  is reimplemented.

## `beforeSend`

It must answer before an event is stored, which an asynchronous bridge can't. Run it in the
wrapper's language on every event the app tracks (`track`, `trackScreenView`) before
forwarding, with the rules of "Redaction before storage". The SDK's automatic events
(`Session Started`, the `Application …` events) carry no app-supplied values and don't pass
through it; the wrapper's README says so.

## A fallback in the wrapper's language

A wrapper may carry its own implementation for where the native module isn't linked (Expo
Go, unit tests). It follows the interface like any SDK, and never runs beside this one for
the same workspace on a device.
