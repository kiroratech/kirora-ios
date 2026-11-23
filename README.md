# Kirora iOS SDK

Connect your iOS app's signed-in users to their Kirora contacts. Track their events for segments, journeys, goals and campaigns, and register their devices for push notifications.

The SDK has an offline event queue, session tracking, separate consent controls and an optional notification service extension for delivery reports, images and buttons. It has no third-party dependencies; FirebaseMessaging is optional and supplied by your app if you send through Firebase.

[Quickstart](#quickstart) · [How Kirora uses this data](#how-kirora-uses-this-data) · [Events and sessions](#events-and-sessions) · [Consent](#consent) · [Push notifications](#push-notifications) · [API reference](#api-reference) · [Troubleshooting](#troubleshooting)

## Installation

Swift 5.9; iOS 13+, Mac Catalyst 14+ and macOS 10.15+. Automatic lifecycle and push handling need UIKit.

In Xcode, choose **File → Add Package Dependencies**, enter `https://github.com/kiroratech/kirora-ios`, choose a release tag and add:

| Product | Target | Purpose |
| --- | --- | --- |
| `Kirora` | Your app | Identity, events, sessions, consent and push |
| `KiroraNotificationService` | Your Notification Service Extension | Delivery reports, images and buttons; independent of `Kirora` |

With CocoaPods (until the pods are published, from a local checkout):

```ruby
target 'MyApp' do
  pod 'Kirora', :path => '../kirora-ios'
end

target 'NotificationService' do
  pod 'KiroraNotificationService', :path => '../kirora-ios'
end
```

For React Native or Flutter, use the Kirora wrapper SDK. Bridge maintainers: see [Wrapper SDKs](docs/wrappers.md).

## Quickstart

### 1. Get your workspace credentials

In Kirora, open **Developer → SDK**. An admin or the owner chooses **Set up the SDK**:

- **Public key** (`kirora_pk_…`): the client key. Include it in your app.
- **Secret key**: the SDK token secret, shown once. Keep it on your server, e.g. as `KIRORA_SDK_TOKEN_SECRET`.

Never put the token secret or a server API key in the app, the extension, source control or logs.

### 2. Return a user token from your server

Add an authenticated endpoint that signs a token for the session's user. Take the user ID from your server's session, never from the app.

The token is an HS256 JWT signed with the SDK token secret, with a string `sub`, `iat`, and an `exp` at most 24 hours after `iat` (one hour is a good start). `sub` is the contact's `externalId` in Kirora: the ID your server uses for that person in Kirora's API. An unknown `sub` becomes a new contact on its first request.

```ts
import { createUserToken } from '@kirora/node';

app.get('/kirora-token', requireSignedIn, (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.type('text/plain').send(
    createUserToken(process.env.KIRORA_SDK_TOKEN_SECRET!, String(req.user.id)),
  );
});
```

`requireSignedIn` and `req.user` are your own auth middleware. Return `401` when nobody is signed in.

### 3. Create one client at launch

Keep one client for the app. For automatic push handling, create it on the main thread before your app delegate's launch method returns.

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

`MyAPI.kiroraToken()` is your app's authenticated request to the endpoint above. It returns the plain-text JWT and throws on network errors, non-success responses or an empty body.

In a SwiftUI app (iOS 14+), attach the same delegate with `@UIApplicationDelegateAdaptor(AppDelegate.self)`.

Creating the client never throws or blocks your thread, and doesn't sign anyone in. With push on, it may finish a device detachment an earlier logout left unconfirmed, using the device secret.

### 4. Apply the user's tracking choice

With `requireTrackingConsent: true`, nothing is tracked until your consent flow calls:

```swift
AppServices.kirora.setTrackingConsent(true)  // or false when the user refuses or withdraws
```

Without it (the default is `false`), tracking is allowed until you call `setTrackingConsent(false)`.

### 5. Identify and track

Once your app has a signed-in user, at sign-in and at every launch:

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
    } catch {
        // Keep the app usable; identify again once auth or connectivity recovers.
    }
}
```

Events are sent automatically. To check your setup, call `await kirora.flush()` and look for the event in Kirora (`flush()` is an attempt, not a delivery receipt).

## How Kirora uses this data

The person signed in to your app is a **contact** in Kirora, matched by the token's `sub` (the contact's `externalId`). Every event the SDK sends belongs to that contact, and Kirora uses it like events your server tracks through the API:

- **Segments** can select contacts by an event, how often and how recently it happened, with property filters, e.g. everyone with an `Order Completed` whose `total` is over 50 in the last 30 days. Push reachability conditions also use the device's language, app version and OS version, sent when it registers for push.
- **Journeys** can start when an event happens, filter entry on its properties, and exit on another event. An event that reaches Kirora more than 72 hours after it happened doesn't start a journey, but still counts for segments and goals.
- **Goals** are measured from your own events (Starter plan and above).
- **Campaigns** send to a list, a segment or rules; a push campaign names the push app.

The SDK doesn't set contact attributes (name, email, plan): set those from your server. It tracks nothing anonymously: events from before sign-in wait on the device and are sent as the next user to sign in.

## Identity and logout

```swift
try await kirora.identify()      // Uses fetchUserToken.
try await kirora.identify(token) // Uses a token you already have.
```

**Call `identify()` at every launch while your app has a signed-in user.** Tokens are kept only in memory, so after a relaunch nobody is signed in to the SDK until you do; until then, events wait on the device.

Events tracked before sign-in go to the next user who signs in. An event tracked while user A is signed in is only ever sent as A, never as B.

With `fetchUserToken`, the SDK fetches a fresh token before the current one expires, when the app returns after it expired, and once on a `401`. A replacement token must name the same user. If the device's clock is wrong, the token's lifetime is counted from when it arrived.

When a token fails in the background, `onAuthenticationFailed` is called on the main thread, once per failure, with `.fetchFailed` (`fetchUserToken` threw, returned nothing or timed out) or `.refused` (Kirora answered `401` and no fresh token was accepted). Events are kept, and the next `identify()` sends them. Sign the user out, or ask them to sign in again:

```swift
onAuthenticationFailed: { reason in
    AuthSession.shared.expire() // Your app's own sign-in flow.
}
```

Call `logout()` from your app's sign-out only, before clearing your own authentication:

```swift
await kirora.logout()
```

Logout tries to send the user's events and detach the device within five seconds, then clears the user and the events they left. Anything tracked, and any `identify()` made, during logout belongs to the next user. Overlapping logouts run one after another.

Detaching uses the outgoing user's token, or the device secret (random bytes that can only detach this device) when nobody is signed in to the SDK or the token is refused. **Offline logout is not immediate revocation:** a failed detach is saved and retried for up to 24 hours, including after a relaunch, and can't undo a newer registration.

## Events and sessions

```swift
kirora.track("Lesson Completed", properties: ["lesson_id": "lesson-12"])
kirora.trackScreenView("Checkout") // "Screen Viewed" with a name property; screens aren't detected automatically
```

Names are case-sensitive; keep them stable to match your segments, journeys and goals:

- Event names in Title Case, object then past-tense action (`Order Completed`), up to 128 characters, at most 1,000 distinct names per workspace. Put variable details in properties.
- Property names in lowercase `snake_case`, up to 64 characters; at most 16 KB of properties per event.
- Names beginning with `contact.` are Kirora's own.

Kirora refuses an event that breaks these, and the SDK drops it, logs it and sends the rest.

Property values may be strings, finite numbers, booleans, `NSNull`, arrays and string-keyed dictionaries; dates become ISO 8601 strings, URLs and UUIDs strings. An unsupported value drops the event with a log, never a throw. Properties are copied when you call `track`.

Each event carries a `context`: app name, version, build and bundle id; OS version; screen size; the SDK's random device id; the session id; language and time zone. No device model, hardware or advertising id.

### Redact before storage

`beforeSend` can change or drop each event before it's stored:

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

It runs once per event, automatic ones included. Return `nil` (or throw) to drop it. Kirora refuses context fields it doesn't know, so don't add any.

### Sessions and lifecycle events

Sessions are on by default: a new visit tracks `Session Started`, and events carry `context.sessionId`. A visit ends after 30 minutes without activity. Set `trackSessions: false` to turn this off.

With `trackAppLifecycle: true`, the SDK also tracks `Application Installed`, `Application Updated`, `Application Opened` and `Application Backgrounded`.

### Delivery and storage

- Events are sent at 20 queued, otherwise after about 30 seconds, and when the app goes to the background or comes back online. Batches hold up to 100 events.
- Failures back off to about five minutes, honouring `Retry-After`. Events keep their idempotency key and capture time on retry, so they're never counted twice.
- An event Kirora refuses as invalid is dropped alone; the rest are sent.
- The queue keeps up to 1,000 events (1 MB) on disk, dropping the oldest. Writes are batched about once a second, so a crash can lose the last second of events.

## Consent

| Control | Scope | Effect |
| --- | --- | --- |
| `setTrackingConsent(_:)` | This device and workspace | Behavioural events, sessions and influenced app-open reports |
| `requestPushPermission()` | iOS notification permission | Asks iOS whether notifications may be shown |
| `setPushEnabled(_:)` | This device and workspace | Registers or detaches this device; survives logout |
| `setPushConsent(_:)` | The signed-in user | Records their marketing push choice with Kirora |

Withdrawing tracking clears queued events and ends the session; data Kirora already accepted is not recalled. Push registration, delivery reports and taps are operational and don't depend on tracking consent. Transactional push needs iOS permission; marketing push also needs the user's marketing consent.

The tracking choice is saved, and a saved refusal always wins. If the saved choice can't be read, tracking waits.

## Push notifications

### Enable push

1. Add the **Push Notifications** capability to your app target.
2. In Kirora, set up an iOS push app with your APNs `.p8` key, key ID, team ID and bundle ID.
3. Add `push: .enabled` to the client's options, or `KiroraPushOptions(pushAppId: "…")` to choose a particular push app.
4. Identify the user, then ask for permission at a suitable moment:

```swift
let permission = await kirora.requestPushPermission() // .granted, .denied, .unanswered or .unsupported
let status = await kirora.getPushStatus()             // .enabled, .disabled, .denied, .unanswered or .unsupported
```

`.granted` also turns push back on if `setPushEnabled(false)` turned it off, and registers the device. Check `getPushStatus()` to see whether registration succeeded.

The SDK hooks the APNs callbacks and notification taps automatically. It registers again when the user or token changes, or after a day, sending the app and OS versions, language and time zone.

**Firebase:** if your push app uses FCM, install and configure FirebaseMessaging (with its APNs key) in your app. Kirora reads its token at runtime. In Firebase's installation-ID mode (FirebaseMessaging 12.16 or later, with `FirebaseMessagingInstallationIdEnabled` set to `YES` in Info.plist), Kirora registers the device with Firebase and sends its installation ID instead.

### Device preference and marketing consent

```swift
await kirora.setPushEnabled(false) // Detach this device, for any user.
await kirora.setPushEnabled(true)  // Register again if iOS permission is granted; no prompt.

try await kirora.setPushConsent(true) // The signed-in user's marketing choice.
```

`setPushConsent` throws if Kirora didn't record the choice, including when nobody is signed in: don't show it as saved until it returns.

### Taps, foreground display and links

Kirora handles only its own pushes (those with the top-level `kirora` marker). A tap reports `opened`, or `clicked` when it has a link. Kirora's pushes are always shown in the foreground; anyone else's go to your notification delegate.

Links open with `UIApplication.open` by default: the browser, or the app that owns the link. To route them yourself, set `handleDeepLink`, which runs on the main actor and returns `true` when your app handled the URL. To keep your own universal links in the app, list their hosts in Info.plist under `KiroraUniversalLinkHosts` (an array: `shop.example.com`, or `*.example.com`); they then go to your app delegate's `application(_:continue:restorationHandler:)`. **In a scene-based app, claim your universal links in `handleDeepLink`**, or they open in the browser. `javascript:`, `data:`, `file:` and `vbscript:` links are refused.

**Buttons need the Notification Service Extension** ([below](#delivery-reports-and-images)). A button opens the app, reports `clicked` and opens its link. iOS shows a push's buttons when the user presses and holds it. If your app calls `setNotificationCategories`, it replaces Kirora's: buttons on pushes already delivered disappear.

To hear taps in your own code:

```swift
Kirora.addNotificationClickListener { tap in
    // tap.data: the push's keys, your own included. tap.buttonIndex: nil for the
    // notification itself. tap.link: the link the SDK opened, if any.
}
```

It's called on the main thread after the link is opened and the tap reported (or after 1.5 seconds, if the report is slow). It can be added before the client exists: the tap that launched the app is held for the first listener. Keep the returned registration to `remove()` it.

### Manual integration

To forward callbacks yourself, set `KiroraAppDelegateProxyEnabled` to `NO` in Info.plist, set your own `UNUserNotificationCenter.current().delegate` at launch (and keep it alive), and forward:

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
    completionHandler() // Your handling for other providers.
}

nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                            willPresent notification: UNNotification,
                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if Kirora.userNotificationCenter(center, willPresent: notification,
                                     withCompletionHandler: completionHandler) { return }
    completionHandler([]) // Your presentation policy for other providers.
}
```

When these return `true`, Kirora calls the completion handler (possibly a moment later); don't call it yourself.

### Delivery reports and images

Add a **Notification Service Extension** target, add the `KiroraNotificationService` product to it, and replace the generated class with:

```swift
import KiroraNotificationService

final class NotificationService: KiroraNotificationServiceExtension {}
```

It reports the push delivered, attaches its image and adds its buttons, then shows it. It needs no client key or App Group.

If you already have an extension, call `KiroraNotificationService.didReceive(_:withContentHandler:)` first; when it returns `false`, the push isn't Kirora's and is yours to handle. Forward expiry as `KiroraNotificationService.serviceExtensionTimeWillExpire(for: request)`.

If the app sets `apiUrl`, add a `KiroraApiUrl` string with the same address to the **extension's** Info.plist.

Without the extension, there are no delivery reports, images or buttons. Taps still work.

## API reference

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `clientKey` | Required | Workspace's public SDK key |
| `fetchUserToken` | `nil` | `@Sendable () async throws -> String?`; fetches a token from your server (30-second timeout). Throw or return `nil` when there's none: `identify()` then throws `UserTokenError` |
| `push` | `nil` | `.enabled` or `KiroraPushOptions(pushAppId:)` |
| `requireTrackingConsent` | `false` | Track nothing until `setTrackingConsent(true)` |
| `trackSessions` | `true` | Session events and `context.sessionId` |
| `trackAppLifecycle` | `false` | Automatic application lifecycle events |
| `logLevel` | `.error` | `.none`, `.error` or `.debug` |
| `onAuthenticationFailed` | `nil` | `@MainActor @Sendable (AuthenticationFailureReason) -> Void`; the user's token failed in the background |
| `handleDeepLink` | `nil` | `@MainActor @Sendable (URL) -> Bool`; your own push-link routing |
| `apiUrl` | `https://api.kirora.io` | API address for staging or private deployments |
| `beforeSend` | `nil` | Change or drop each event before it's stored |

### Methods

| Method | Result / behaviour |
| --- | --- |
| `identify(_ userToken: String? = nil) async throws` | Signs a user in; sends their waiting events and registers for push |
| `logout() async` | Sends events and detaches the device (five seconds at most), then signs out |
| `track(_ name: String, properties: [String: Any] = [:])` | Queues an event; never throws |
| `trackScreenView(_ name: String)` | Queues `Screen Viewed` |
| `setTrackingConsent(_ granted: Bool)` | Applies and saves the tracking choice |
| `trackingConsent: Bool` | Whether tracking is allowed now |
| `requestPushPermission() async -> PushPermission` | Asks iOS for permission when needed, then registers |
| `getPushStatus() async -> PushStatus` | Permission and registration status; never prompts |
| `setPushEnabled(_ enabled: Bool) async` | This device's push preference; never throws |
| `setPushConsent(_ granted: Bool) async throws` | The signed-in user's marketing choice |
| `getState() -> KiroraState` | Local snapshot for diagnostics; no network request |
| `flush() async` | Tries to send queued events now |
| `destroy()` | Stops the client; queued events stay for the next one |
| `Kirora.addNotificationClickListener(_:) -> KiroraListenerRegistration` | Static. Hears taps on Kirora pushes and their buttons |

`KiroraState` has `isInitialized`, `isIdentified`, `deviceId`, `sessionId`, `pushToken`, `trackingConsent`, `pushConsent` and `queuedEventCount`. It's for diagnostics, not proof that Kirora accepted anything.

### Errors

- `KiroraApiError` (a `KiroraError`): the API's status, optional `code` and `retryAfterMs`.
- `UserTokenError`: `fetchUserToken` threw, returned nothing or timed out; `underlying` is the cause.
- `KiroraError`: a setup or network failure.

`track()` never throws; refused events are logged under the subsystem `io.kirora.sdk`. Keep sensitive values out of event names.

## Privacy and local storage

The SDK never sends hardware or advertising identifiers: no IDFA, IDFV, Keychain or device model, and no App Tracking Transparency prompt. The device id is a random UUID kept in the app's storage, scoped to the client key and the API's host and port, and deleted with the app.

For push, it sends the app and OS versions, language and time zone when it registers; when a Kirora push is delivered or tapped; and, with tracking consent, when the app is opened (influenced opens).

Files live under `Application Support/io.kirora.sdk/`, excluded from backups, inside the app's sandbox; the SDK adds no encryption of its own. Keep credentials and unneeded sensitive data out of event properties.

| Storage | Contents |
| --- | --- |
| `events-<hash>.json` | The queued events |
| `state.json` | Device id and secret, visit, preferences, last push registration |
| `consent.json` | A second copy of a tracking refusal |
| Extension's `UserDefaults` | The order of Kirora's button categories |
| Memory only | User tokens |

Both products include a `PrivacyInfo.xcprivacy` manifest. Your App Store disclosures must still cover the events and properties you choose to send.

## Verify your integration

1. Your token endpoint returns `401` when signed out, and a token naming the session user when signed in.
2. With opt-in, nothing is tracked before consent; after consent and `identify()`, an event shows in Kirora.
3. Events stay with the right user across offline use, account switches and restarts.
4. On a provisioned device: permission, foreground display and a tap that launches the app.
5. A real campaign push (not a dashboard test, which may carry no tracking) shows delivery and tap reports.
6. Images and buttons, with the extension, and offline logout.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Events stay queued | `identify()`, the tracking choice, connectivity and the token endpoint. |
| `401` or token error | The token secret, `sub`, expiry and your token request. Never log the token. |
| No APNs token | Push capability, bundle ID and provisioning; callback forwarding if the proxy is off. |
| No Firebase token or installation ID | FirebaseMessaging, `FirebaseApp.configure()` and Firebase's APNs key. |
| Permission granted but status disabled | Identify the user, `setPushEnabled(true)`, and check the logs for registration errors. |
| No image or delivery report | The extension target and product; dashboard tests may carry no tracking. |
| No action buttons | The extension; press and hold the notification; your app isn't calling `setNotificationCategories`. |
| Link opens in the browser | List the host in `KiroraUniversalLinkHosts`, or handle it in `handleDeepLink` (required in scene-based apps). |
| No reports with a custom `apiUrl` | Set `KiroraApiUrl` in the extension's Info.plist. |

## Support and contributing

Report integration issues in this repository's issues, with your SDK and iOS versions. Send vulnerabilities to **security@kirora.io**; see [SECURITY.md](SECURITY.md). For development, see [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).

Licensed under the [MIT License](LICENSE).
