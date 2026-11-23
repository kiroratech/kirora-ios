# Working on the Kirora iOS SDK

Instructions for AI coding agents changing this repository. To install the SDK in an app,
see the [README](README.md) instead.

## Ground rules

- The behaviour every Kirora client SDK shares (options, methods, delivery, sessions,
  consent, push reporting, the `/client/v1` wire contract) is defined in Kirora's client
  SDK interface, `docs/sdk-interface.md` in the omnichannel repo. Change it there first;
  don't add public options or methods here on your own. The web SDK (`kirora/web-sdk`)
  is the first implementation: where this one differs from it without a platform reason,
  one of them is a bug.
- Zero dependencies. Don't add one. `KiroraNotificationService` depends on nothing, not
  even `Kirora`: it runs in an app extension.
- A failing Kirora must never break the host app: no throwing from `track()`, the
  initializer, or anything on a timer, and nothing that blocks launch.
- An event tracked while a user is signed in is only ever sent with that user's token.
- No hardware or advertising ids: no IDFA, IDFV, Keychain or device model.
- iOS 13 and later. Check APIs against it.

## Layout

- `Sources/Kirora/Kirora.swift`: the public client, wiring the parts below.
- `Sources/Kirora/Internal/`: identity and tokens, the API transport, the on-disk event
  queue, delivery (an actor), visits and the tracker, lifecycle.
- `Sources/Kirora/Push/`: registration, app opens, tap handling, and the UIKit
  integration (app-delegate swizzle, notification-center delegate proxy), which is the
  only code behind `#if canImport(UIKit)`.
- `Sources/KiroraNotificationService/`: the extension helper.
- `Sources/Kirora/Wrapper/`: what wrapper SDKs (React Native, Flutter) call, as
  `@_spi(Wrapper)`; not for apps.
- `Kirora.podspec`, `KiroraNotificationService.podspec`: CocoaPods, for apps, from a release
  tag (not on trunk). The React Native and Flutter SDKs bundle a copy of `Sources/Kirora/`
  instead, compiled into their own module, so its file names must stay unique (a test
  checks); see `docs/wrappers.md`.
- `Tests/KiroraTests/`: swift-testing, against a fake Kirora (`Support.swift`). UIKit is
  behind protocols (`AppLifecycleSource`, `PushPlatform`), so the tests run on macOS.

## Before finishing

    ./scripts/test.sh
    swift build -Xswiftc -strict-concurrency=complete

and typecheck the UIKit code (Mac Catalyst works without the iOS SDK):

    SDK=$(xcrun --show-sdk-path)
    swift build --triple arm64-apple-ios15.0-macabi --sdk "$SDK" \
      -Xswiftc -Fsystem -Xswiftc "$SDK/System/iOSSupport/System/Library/Frameworks" \
      -Xswiftc -strict-concurrency=complete --scratch-path .build/catalyst

With Xcode installed, also build for iOS: `xcodebuild -scheme Kirora-Package -destination 'generic/platform=iOS'`.

Update the README if public behaviour or setup changed, and `CHANGELOG.md` for any change
users will notice. Bump `sdkVersion` in `Sources/Kirora/Internal/Support.swift` on release, and `s.version`
in `Kirora.podspec` and `KiroraNotificationService.podspec` to match (a test checks); tag
the release with the same version, as the podspecs' `source` names it. The wrapper SDKs
refresh their bundled copy from that tag.

`@_spi(Wrapper)` (`Sources/Kirora/Wrapper/`) is what the React Native and Flutter SDKs use:
change it only with them, and with "Wrapper SDKs" in the interface. See `docs/wrappers.md`.
