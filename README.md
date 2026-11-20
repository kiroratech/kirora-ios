# Kirora iOS SDK

Connect customer activity in your iOS app to Kirora. Track events for signed-in users, automate follow-ups and register devices for push notifications.

The SDK provides a bounded offline event queue, session tracking, separate consent controls and an optional notification service extension for delivery reports and images. It has no third-party package dependencies. FirebaseMessaging is optional and supplied by your app when you send through Firebase.

[Quickstart](#quickstart) · [Events and sessions](#events-and-sessions) · [Consent](#consent) · [Push notifications](#push-notifications) · [API reference](#api-reference) · [Troubleshooting](#troubleshooting)

## Installation

The package declares Swift tools 5.9 and supports iOS 13+, Mac Catalyst 14+ and macOS 10.15+. Automatic app lifecycle and push integration require UIKit. A macOS build does not verify an iOS integration.

In Xcode, choose **File → Add Package Dependencies** and enter:

```text
https://github.com/kiroratech/kirora-ios
```

Choose a release tag available in the repository and add products to the appropriate targets:

| Product | Target | Purpose |
| --- | --- | --- |
| `Kirora` | Your app | Identity, events, sessions, consent and push registration/taps |
| `KiroraNotificationService` | Your Notification Service Extension | Delivery reports and image attachments; independent of `Kirora` |

For a source checkout, add the local package in Xcode, or use a local SwiftPM dependency:

```swift
.package(path: "../kirora-ios")
```

Add `.product(name: "Kirora", package: "kirora-ios")` to your app target's dependencies. Add `KiroraNotificationService` only to the extension target.

### CocoaPods

Both products have podspecs. For a local checkout:

```ruby
target 'MyApp' do
  pod 'Kirora', :path => '../kirora-ios'
end

target 'NotificationService' do
  pod 'KiroraNotificationService', :path => '../kirora-ios'
end
```

Use the distribution and version documented by your release when installing remotely. A podspec in this repository does not establish that its version is published to the CocoaPods registry.

For React Native or Flutter, use the corresponding Kirora wrapper. Native bridge maintainers should read [Wrapper SDKs](docs/wrappers.md).

## Quickstart

### 1. Get your workspace credentials

Open **Developer → SDK** in Kirora:

- **Client key** (`kirora_pk_…`): public; include it in your app.
- **Token secret**: private; keep it on your server.

Never include the token secret or a server API key in the app, notification extension, source-controlled configuration or logs.

### 2. Return a user token from your server

Create an authenticated endpoint that signs a token for the current session user. Derive the user ID from your server's authenticated session, rather than accepting a user ID supplied by the app.

A token is an HS256 JWT signed with the workspace's SDK token secret. It needs a string `sub`, an `iat` timestamp and an `exp` no more than 24 hours after `iat`. A one-hour lifetime is a useful starting point.

With the Kirora Node.js library:

```ts
import { createUserToken } from '@kirora/node';

app.get('/kirora-token', requireSignedIn, (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.type('text/plain').send(
    createUserToken(process.env.KIRORA_SDK_TOKEN_SECRET!, String(req.user.id)),
  );
});
```

`requireSignedIn` and `req.user` represent your app's authentication middleware. Return `401` when there is no authenticated user.

### 3. Retain one client and initialise it at launch

Use one client for the app's workspace. For automatic push handling, initialise it on the main thread before the app delegate's launch method returns.

```swift
import Kirora
import UIKit

enum AppServices {
    static let kirora = Kirora(options: KiroraOptions(
        clientKey: "kirora_pk_…",
        fetchUserToken: { try await MyAPI.kiroraToken() },
        requireTrackingConsent: true
    ))
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        _ = AppServices.kirora
        return true
    }
}
```

`MyAPI.kiroraToken()` is your app's authenticated request to the endpoint above. It must return the plain-text JWT and throw on network failures, non-success responses or an empty response. Send your app's credentials only to your own server.

For a SwiftUI app (iOS 14+), retain the same delegate with `@UIApplicationDelegateAdaptor`:

```swift
import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Creating the client does not identify a user or make an authenticated Kirora request. It does not throw, and it never waits for its files on your thread: they're read in the background, and launch handling runs off the main thread once they are.

### 4. Apply the user's tracking choice

The example requires opt-in. Call this from your consent flow after the user answers:

```swift
AppServices.kirora.setTrackingConsent(true) // The user granted behavioural tracking.
```

Pass `false` when the user refuses or withdraws consent. Do not automatically grant consent to make an integration check pass. If your app does not require prior opt-in, the option defaults to `false`; a remembered refusal still takes precedence.

### 5. Identify and track

After your app restores the authenticated session, identify the user. Repeat this at each app start while they remain signed in:

```swift
let kirora = AppServices.kirora

Task {
    do {
        try await kirora.identify()
        kirora.track("Order Completed", properties: [
            "order_id": "1042",
            "total": 46.5,
            "currency": "USD"
        ])
        await kirora.flush() // Optional for verification; normal delivery is automatic.
    } catch {
        // Keep your app usable; retry identification after authentication/connectivity recovers.
    }
}
```

Check the event in Kirora. A returned `flush()` means the attempt finished, not that every event was accepted.

## Identity and logout

```swift
try await kirora.identify()      // Uses fetchUserToken.
try await kirora.identify(token) // Uses a token you already obtained.
```

The SDK sends no anonymous behavioural requests. Events tracked before identification, while tracking is allowed, wait on the device for the next user. Once adopted, they retain that user's identity across retries and restarts. Events captured while A is signed in never become B's events. If a never-accepted token is refused, its adopted pre-sign-in events can be released for a later sign-in.

With `fetchUserToken`, the SDK asks for a fresh token 60 seconds before the current one's `exp`, when the app returns to the foreground after it has expired, and once when a request receives `401`. A replacement must name the same user. Tokens stay in memory; they are not written into queued events.

A `401` that no fresh token resolves keeps the events. With `fetchUserToken`, sending backs off (to about five minutes) instead of asking for a token on every attempt; without it, nothing is sent as that token again. Either way, the next `identify()` sends them.

When the token fails in the background (sending events, registering for push), `onAuthenticationFailed` is called on the main thread with `.fetchFailed` (`fetchUserToken` threw or timed out) or `.refused` (Kirora answered `401` and no fresh token was accepted: refused too, or none to try, without `fetchUserToken`). It's called once per failure, not per retry: again only after a request succeeds or another `identify()`. It isn't called for a failure `identify()` or `setPushConsent(_:)` throws, or while the user is signing out. Sign the user out, or ask them to sign in again:

```swift
onAuthenticationFailed: { reason in
    AuthSession.shared.expire()   // Your app's own sign-in flow.
}
```

With push disabled, `identify(token)` selects the token locally. Server acceptance is established by a subsequent authenticated request, not by that method returning alone.

Call Kirora logout before clearing your app's own authentication:

```swift
await kirora.logout()
```

Logout attempts event delivery and device detachment within a total five-second deadline, including an identification already in progress. It then clears the selected user and their remaining behavioural events. Activity captured during logout waits for the next user.

Failed device detachment is retried in memory using the outgoing identity, with backoff, for up to 24 hours. The request names the last successful registration's `lastSeenAt`, so a late detach cannot undo a newer registration when the server implements that contract. Ensure the deployed API supports it.

**Offline logout is not immediate server-side revocation.** Cleanup retries end when the app process ends or the client is destroyed. A request already accepted by Kirora cannot be recalled. Cleanup uses the outgoing user's token as captured and never asks `fetchUserToken` for a fresh one: a `401` ends it.

## Events and sessions

```swift
kirora.track("Lesson Completed", properties: ["lesson_id": "lesson-12"])
kirora.trackScreenView("Checkout")
```

Screens are tracked explicitly. Names are case-sensitive; use stable names that match your segments, journeys and goals. Put variable details in properties rather than event names. Names beginning with `contact.` are reserved by Kirora.

Properties are copied synchronously at capture. Use JSON-compatible strings, finite numbers, booleans, `NSNull`, arrays and string-keyed dictionaries. Dates become ISO 8601 strings; URLs and UUIDs become strings. An absent optional dictionary member is omitted; use `NSNull()` for an explicit null. An unsupported value drops the event and produces a diagnostic rather than throwing into your app.

Events carry a `context` in the fields Kirora accepts: `app` (name, version, build, bundle id as `namespace`), `os` (`iOS` and its version), `screen` (portrait width and height in points, and scale as `density`), `device` (the SDK's random `id`, `manufacturer` `Apple`, `type` `ios`; no model, hardware or advertising id), an optional `sessionId`, and the device language and time zone. Kirora refuses any other context field, so a `beforeSend` that adds one gets that event dropped. Kirora records the request IP address and user agent on the server. These event/context fields follow behavioural tracking consent.

### Redact before storage

Use `beforeSend` to remove sensitive fields or drop an event before it enters the offline queue:

```swift
let options = KiroraOptions(
    clientKey: "kirora_pk_…",
    beforeSend: { event in
        var redacted = event
        redacted.properties.removeValue(forKey: "email")
        return redacted
    }
)
```

The synchronous hook runs once for each behavioural event, including automatic events, after context is assembled. Return `nil` to drop it. Throwing or returning values that cannot be serialised also drops it. Retry uses the redacted snapshot; it does not call the hook again. The SDK retains the original event name, timestamp, owner and idempotency key. Recursive tracking from the hook is rejected.

### Sessions and lifecycle events

Sessions are enabled by default. A new visit emits `Session Started`; events carry `context.sessionId`. Activity and foreground time keep the visit alive. After 30 minutes of inactivity, the next activity starts a new visit. A relaunch can continue the stored visit; changing users starts a different user's visit. Set `trackSessions: false` to disable session events and IDs.

With `trackAppLifecycle: true`, the SDK also records `Application Installed`, `Application Updated`, `Application Opened` and `Application Backgrounded`. Lifecycle tracking is off by default and subject to behavioural tracking consent.

### Delivery and storage

- Delivery starts at 20 queued events, otherwise after about 30 seconds, and is attempted on backgrounding and connectivity recovery.
- Batches hold at most 100 events and target 200,000 encoded bytes. A batch that is too large (`413`) or invalid (`422`, or a `400` whose `errors` name a field under `events`) is split to isolate the event at fault, which alone is dropped. A `400` naming only other fields (a refused header), or none (a proxy's page), is kept and retried.
- A refusal of the whole request that no event caused (a redirect, `403`, `404`, `409`, or a `400` naming a header), as a wrong `apiUrl`, a proxy or a captive portal answers, keeps the events and backs off like a network failure. `403 PLAN_FEATURE_UNAVAILABLE` drops the batch: the plan doesn't take those events.
- The disk queue holds at most 1,000 events and 1,000,000 encoded bytes, including ownership metadata. Oldest records are dropped when either budget is exceeded.
- Network failures and retryable responses back off exponentially to about five minutes, with jitter. `Retry-After` is honoured; unusually large values are capped at one week.
- Each event retains its idempotency key and capture time on retry. A batch's `sentAt` lets the API correct device-clock skew for behavioural events.
- Accepted events and terminal refusals leave the queue. Temporary per-event refusals and missing/duplicate acknowledgements remain queued. A result that is neither Kirora's accepted nor its refused shape leaves the event queued for a retry.
- Storage writes are asynchronous. Unavailable storage falls back to a bounded in-memory queue; recent writes can be lost on abrupt termination. Background execution and delivery are best effort.

## Consent

These controls have different purposes:

| Control | Scope | Effect |
| --- | --- | --- |
| `setTrackingConsent(_:)` | Device/workspace tracking preference | Controls behavioural events, sessions and influenced app-open reports |
| `requestPushPermission()` | iOS notification authorisation | Asks the OS whether notifications may be shown |
| `setPushEnabled(_:)` | Device/workspace preference | Enables or detaches this installation; survives logout |
| `setPushConsent(_:)` | Signed-in user's marketing choice | Records marketing push consent with Kirora |

Withdrawing tracking clears queued behavioural events and influenced app opens, ends the session and cancels further behavioural delivery where possible. A push device ID may remain while registration or cleanup needs it. Previously accepted server data is not recalled.

Operational push registration, notification delivery receipts and taps remain separate from behavioural tracking consent. Transactional push needs OS permission; marketing push also needs the user's marketing consent. Tracking refusal does not turn notifications off or withdraw marketing push consent.

The tracking choice is persisted per workspace. Refusals are stored independently in `state.json` and `consent.json`, so either refusal wins if the other copy is lost. With `requireTrackingConsent: true`, an unreadable choice blocks tracking until a fresh answer. Without it, tracking follows the fresh-install default only if the independent refusal copy can be read and contains no refusal. If neither copy can be read, tracking waits. Persistence failures are logged; the current in-memory choice still applies.

## Push notifications

### Enable push

1. Add **Push Notifications** to your app target's capabilities and use a matching provisioning profile.
2. Configure an iOS push app and its credentials in Kirora. For APNs, provide the `.p8` key, key ID, team ID and bundle ID.
3. Add `push: .enabled` to the retained client's options. Use `PushOptions(pushAppId: "…")` if you need to select a particular iOS push app.
4. Identify the signed-in user, then request permission at a suitable point in your app:

```swift
let permission = await kirora.requestPushPermission()
```

The permission result is `.granted`, `.denied`, `.unanswered` or `.unsupported`. Granted permission does not itself confirm successful Kirora registration. Query registration status separately:

```swift
let status = await kirora.getPushStatus()
// .enabled, .disabled, .denied, .unanswered or .unsupported
```

The SDK automatically observes APNs callbacks and notification taps by default. Registration is refreshed when the user or token changes, or the previous registration is a day old. Registration sends app/OS versions, language and time zone. It does not send a device model or advertising ID.

### Firebase

Kirora's push-app configuration chooses APNs or FCM tokens. For FCM, install and configure FirebaseMessaging in your app and configure its APNs credentials. Kirora reads Firebase's token at runtime without linking it as a package dependency. Do not pass an FCM token to Kirora's APNs callback.

### Device preference and marketing consent

```swift
await kirora.setPushEnabled(false) // Detach this device; keep the preference across users.
await kirora.setPushEnabled(true)  // Register if OS permission is already granted; no prompt.

try await kirora.setPushConsent(true) // Signed-in user's marketing choice.
```

`setPushConsent` throws if Kirora has not recorded the choice, including when nobody is signed in. Do not show it as saved merely because your app updated its own control.

### Taps, foreground display and links

Kirora handles only notifications carrying the top-level `kirora` marker. Test notifications without `trackingUrl` produce no reports. Taps post `opened`, or `clicked` when the tapped notification/button has a link. Dismissals are not opens.

A Kirora notification is presented in the foreground unless your own notification delegate implements `willPresent` and chooses otherwise. The automatic integration forwards notification callbacks to the app's delegate. A delegate that leaves a Kirora push unanswered (some libraries ignore notifications they didn't schedule, without calling the completion handler) has it shown for it after 1.5 seconds, instead of it being dropped; answer `[]` to hide one.

Use `handleDeepLink` for explicit routing. It runs on the main actor and returns `true` when your app handled the URL. Return `false` for SDK default routing. By default a web link goes to your app delegate's `application(_:continue:restorationHandler:)` and stays in the app if that returns `true`; anything else, custom schemes included, opens with `UIApplication.open` (the browser, or whichever app owns the link). A scene delegate is never handed a link, as `scene(_:continue:)` can't report whether it took it: **in a scene-based app, claim your own universal links in `handleDeepLink`**, or they open in the browser. Links using `javascript:`, `data:`, `file:` or `vbscript:` are rejected.

**Buttons need the Notification Service Extension** ([below](#delivery-reports-and-images)): iOS shows buttons only from a notification category, which the extension makes from the push's `buttons` and adds to the app's own categories. Without it, a Kirora push shows no buttons. A button opens the app; the SDK reports `clicked` and opens the button's link as it does for the notification's. If your app calls `setNotificationCategories` at launch, it replaces Kirora's categories then: buttons on pushes already delivered disappear (new pushes register theirs again). A push whose payload already names a `category` keeps it.

To hear taps in your own code, with the push's data:

```swift
Kirora.addNotificationClickListener { tap in
    // tap.data: the push's keys, your own data included. tap.buttonIndex: nil for the
    // notification itself. tap.link: the link the SDK opened, if any.
}
```

It may be added before the client exists, and is called on the main thread after the tap is reported and its link opened. A tap heard before any listener (the one that launched the app) is held, the latest ten, for the first listener added. Keep the returned registration to `remove()` it later.

### Manual integration

To forward callbacks yourself, set `KiroraAppDelegateProxyEnabled` to Boolean `NO` in the app's Info.plist before SDK initialisation. Forward both APNs callbacks and the notification delegate callbacks:

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Kirora.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
}

func application(_ application: UIApplication,
                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Kirora.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
}

nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    if Kirora.userNotificationCenter(center, didReceive: response,
                                     withCompletionHandler: completionHandler) { return }
    completionHandler() // Replace with your handling for other providers.
}

nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                            willPresent notification: UNNotification,
                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if Kirora.userNotificationCenter(center, willPresent: notification,
                                     withCompletionHandler: completionHandler) { return }
    completionHandler([]) // Replace with your presentation policy for other providers.
}
```

Import `UIKit`, `UserNotifications` and `Kirora` in the file containing these methods. During launch, assign your retained `UNUserNotificationCenterDelegate` to `UNUserNotificationCenter.current().delegate`. Keep that delegate strongly referenced. A returned `true` means Kirora handled the notification and called the completion handler; do not call it twice.

### Delivery reports and images

Create a **Notification Service Extension** target and add the `KiroraNotificationService` product to that target. Replace the generated implementation with:

```swift
import KiroraNotificationService

final class NotificationService: KiroraNotificationServiceExtension {}
```

Keep the generated extension configuration and principal-class entry. Set a compatible deployment target. Kirora supplies `mutable-content: 1`; custom payloads must also satisfy Apple's notification-extension requirements.

The helper attempts a delivery report, downloads an HTTPS image and registers the push's buttons before finishing. It needs neither a client key nor an App Group: reporting credentials are carried by the notification's `trackingUrl`. The report retries once on network errors, `429` or `5xx`, then is dropped. Reports are best effort and are not recovered through shared App Group storage. Extension expiry hands the available content back to iOS.

For an existing extension, call `KiroraNotificationService.didReceive(_:withContentHandler:)`. If it returns `false`, handle that notification yourself and call its content handler. Forward `serviceExtensionTimeWillExpire()` to Kirora too. Keep other providers' extension processing intact.

Reports go only to a `/t/p/…` address on Kirora's API host (under its path, if `apiUrl` has one), as in the app. The extension can't see the app's options: if the app sets `apiUrl`, add a `KiroraApiUrl` string with the same address to the **extension's** Info.plist.

Without the extension, iOS delivered reports, Kirora image attachments and buttons are unavailable. Taps are still handled by the app.

## API reference

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `clientKey` | Required | Workspace's public SDK key |
| `fetchUserToken` | `nil` | `@Sendable () async throws -> String`; fetches a token from your server, with a 30-second SDK timeout |
| `push` | `nil` | `.enabled` or `PushOptions(pushAppId:)` |
| `requireTrackingConsent` | `false` | Require a tracking grant before behavioural collection |
| `trackSessions` | `true` | Session events and `context.sessionId` |
| `trackAppLifecycle` | `false` | Automatic application lifecycle events |
| `logLevel` | `.error` | `.none`, `.error` or `.debug` |
| `onAuthenticationFailed` | `nil` | `@MainActor @Sendable (AuthenticationFailureReason) -> Void`; the user's token failed in the background |
| `handleDeepLink` | `nil` | `@MainActor @Sendable (URL) -> Bool`; explicit push-link routing |
| `apiUrl` | `https://api.kirora.io` | API origin for staging/private deployments |
| `beforeSend` | `nil` | Synchronous redaction/drop hook before behavioural storage |

### Methods

| Method | Result / behaviour |
| --- | --- |
| `identify(_ userToken: String? = nil) async throws` | Selects a user and attempts queued delivery/push registration |
| `logout() async` | Attempts flush/detach, then clears local identity and that user's remaining events; bounded to five seconds |
| `track(_ name: String, properties: [String: Any] = [:])` | Synchronously captures a snapshot for the queue; never throws |
| `trackScreenView(_ name: String)` | Captures `Screen Viewed`; screens are not automatically detected |
| `setTrackingConsent(_ granted: Bool)` | Applies and persists the tracking choice |
| `requestPushPermission() async -> PushPermission` | Prompts through iOS when appropriate and attempts registration |
| `getPushStatus() async -> PushStatus` | Reads OS permission and registration status; never prompts |
| `setPushEnabled(_ enabled: Bool) async` | Changes this device's push preference; never throws |
| `setPushConsent(_ granted: Bool) async throws` | Records the signed-in user's marketing choice |
| `trackingConsent: Bool` | Whether tracking is allowed now; as `getState().trackingConsent`, without reading the rest |
| `getState() -> KiroraState` | Local diagnostic snapshot; no prompt or network request |
| `flush() async` | Attempts queued delivery without bypassing consent or `Retry-After` |
| `destroy()` | Stops the client; queued events remain for a future client |
| `Kirora.addNotificationClickListener(_:) -> KiroraListenerRegistration` | Static. Hears taps on Kirora pushes and buttons, on the main thread; held taps go to the first listener |

`KiroraState` exposes `isInitialized`, `isIdentified`, `deviceId`, `sessionId`, `pushToken`, `trackingConsent`, `pushConsent` and `queuedEventCount`. It is for diagnostics, not proof of server acceptance or authorisation to send marketing push. `pushToken` is the token of the signed-in user's current registration, and `nil` before sign-in, after a failed registration, while push is off or while it's being detached.

### Errors

SDK errors use the `KiroraError` base class:

- `KiroraApiError`: API status, optional error `code` and `retryAfterMs`.
- `UserTokenError`: token callback failure/timeout, with `underlying` cause.
- `KiroraError`: setup or network failure, with a message and optional underlying error.

Task cancellation can surface separately as `CancellationError`. Event tracking does not throw; rejected events are logged. Logging uses subsystem `io.kirora.sdk`; debug output includes event names and delivery counts. Keep sensitive values out of event names and token-callback errors.

## Privacy and local storage

The SDK uses no IDFA, IDFV, Keychain or device model. It does not request App Tracking Transparency permission. Its installation ID is a random UUID in the app container, scoped to the client key and API deployment.

Files live under `Application Support/io.kirora.sdk/`. The directory is excluded from device backups. Events and state are JSON files protected by the app's storage environment; the SDK adds no application-level encryption. Do not put credentials or unnecessary sensitive data in event properties.

| Storage | Contents |
| --- | --- |
| `events-<hash>.json` | Bounded queued event snapshots, owners and idempotency keys |
| `state.json` | Namespaced installation/session state, preferences, last registration, app version and pending influenced opens; APNs cache; the last `apiUrl`, for a tap that launches the app before the client exists |
| `consent.json` | Independent tracking-refusal copy |
| Extension's `UserDefaults` | The order of Kirora's button categories, so the least recently used go first (declared in the extension's privacy manifest) |
| Memory | User JWTs, active requests and detach retry credentials |

Push registration metadata, notification receipts and taps are operational reports. Influenced app opens require behavioural tracking permission, a signed-in user and a push registration. They are separate from `Application Opened` events and can be reported even with lifecycle-event tracking disabled. Up to 50 pending opens are retained; those older than seven days are discarded. Their 30-minute spacing is saved with the visit; with `trackSessions: false` it's kept in memory only.

Both products include a `PrivacyInfo.xcprivacy` manifest. Review your app's complete data collection and App Store disclosures for the events you choose to send; a bundled SDK manifest does not describe all app-supplied properties.

## Verify your integration

1. Confirm your token endpoint returns `401` signed out and a token naming the session user signed in.
2. Verify that opt-in blocks behavioural events before consent, then check one event in Kirora after consent and identification.
3. Confirm queued events remain with the correct user across offline use, account changes and restarts.
4. Test push on an appropriately provisioned iOS device. Check permission changes, foreground presentation and a tap that launches the app.
5. Use a regular campaign notification to check delivery/tap reporting. A dashboard test without `trackingUrl` cannot verify metrics.
6. Test image attachments with the extension, mixed-provider notifications, custom links and offline logout.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Events stay queued | Identification, tracking choice, connectivity and token endpoint. `flush()` is an attempt, not a delivery receipt. |
| `401` or token error | Workspace secret, authenticated `sub`, token expiry and callback response handling. Never log the token. |
| No APNs token | Push capability, matching bundle/provisioning settings and manual callback forwarding if the proxy is disabled. |
| No Firebase token | FirebaseMessaging installation, `FirebaseApp.configure()` and Firebase's APNs configuration. |
| Permission granted but status disabled | Identify the user, enable device push and inspect registration/network errors. |
| No image or delivered metric | Extension target/product/configuration, valid payload and connectivity; dashboard tests may not carry tracking URLs. |
| Link does not open in the app | In a scene-based app, claim your own universal links in `handleDeepLink`; otherwise they open in the browser. |
| No action buttons | The Notification Service Extension, which makes the buttons; and that the app doesn't replace notification categories after the push arrived. |
| No tap or delivered reports with a custom `apiUrl` | Reports go only to `/t/p/…` on the API host: set `KiroraApiUrl` in the extension's Info.plist. |

## Support and contributing

Report integration issues through the repository's issues with your SDK/iOS versions and a redacted description. Send vulnerabilities to **security@kirora.io**; see [SECURITY.md](SECURITY.md). For development instructions, see [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).

Licensed under the [MIT License](LICENSE).
