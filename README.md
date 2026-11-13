# Kirora iOS SDK

The Kirora SDK for iOS. Track what your signed-in users do, record their consent, and
register their devices to receive push notifications from Kirora.

- Swift Package, zero dependencies, iOS 13 and later
- Batches events and retries failed requests, with a bounded offline queue kept on disk
- Push without app-delegate code: the APNs token and taps are picked up automatically
- Delivery reports and images from a three-line Notification Service Extension

[Quickstart](#quickstart) · [Usage](#usage) · [Push notifications](#push-notifications) ·
[API](#api) · [Privacy](#privacy) · [Troubleshooting](#troubleshooting)

## Installation

In Xcode, choose **File → Add Package Dependencies…** and enter:

```
https://github.com/kiroratech/kirora-ios
```

Choose products by target:

| Product | Add to | Purpose |
| --- | --- | --- |
| `Kirora` | App target | Events, identity, consent, sessions and push registration/taps |
| `KiroraNotificationService` | Notification Service Extension target | Push delivery reports and images; independent of `Kirora` |

The package declares Swift tools 5.9 and supports iOS 13+. The core also builds on macOS
10.15+; automatic app lifecycle and push registration require UIKit. The package declares
Mac Catalyst 14+ support. These build targets do not replace testing on an iOS device.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kiroratech/kirora-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Kirora", package: "kirora-ios")]),
]
```

## Quickstart

### 1. Get your keys

In the Kirora dashboard, go to **Developer → SDK**:

- The **client key** (`kirora_pk_…`) is public and ships in your app.
- The **token secret** is private. Keep it on your server only, never in the app.

### 2. Add a token route to your server

The SDK sends events as the user named in a signed token. Your server must derive that
user from your app's authenticated session, never from an id the app sends.

Sign an HS256 JWT with the token secret: `sub` is your app's user id as a string, `iat`
the current Unix time in seconds, and `exp` at most 24 hours later (one hour is a good
start). Return it as plain text with `Cache-Control: no-store`, and `401` when signed out.
With Node.js, `@kirora/node` does it for you:

```ts
import { createUserToken } from '@kirora/node';

app.get('/kirora-token', requireSignedIn, (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.type('text/plain').send(createUserToken(process.env.KIRORA_SDK_TOKEN_SECRET!, String(req.user.id)));
});
```

### 3. Create the client

Create and retain one client for the whole app. For automatic push integration, initialize
it on the main thread before `application(_:didFinishLaunchingWithOptions:)` returns.
For example, keep it as an app delegate property:

```swift
import Kirora
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    let kirora = Kirora(options: KiroraOptions(
        clientKey: "kirora_pk_…",
        fetchUserToken: { try await MyAPI.kiroraToken() }
    ))
}
```

`MyAPI.kiroraToken()` represents your app's authenticated request to the token route.
It must return the plain-text token and throw for non-success HTTP responses, empty
responses, and network errors. Send your app's session credentials only to your own
server. The SDK supplies the Kirora headers when it sends events.

With the SwiftUI app lifecycle (iOS 14+), keep the client on your `App`:

```swift
import Kirora
import SwiftUI

@main
struct MyApp: App {
    static let kirora = Kirora(options: KiroraOptions(
        clientKey: "kirora_pk_…",
        fetchUserToken: { try await MyAPI.kiroraToken() }
    ))

    init() { _ = Self.kirora }

    var body: some Scene { WindowGroup { ContentView() } }
}
```

Creating the client never throws, waits for a network response or reads the disk: the
SDK's files are read in the background. A call made in the first moments that needs a
stored value (such as tracking consent) waits for that read: a file of a few hundred bytes.

### 4. Identify and send your first event

Once your app has restored its authenticated session, use the retained client:

```swift
Task {
    do {
        try await kirora.identify()
        kirora.track("Order Completed", properties: ["order_id": "1042"])
        await kirora.flush() // Useful for verification; normal delivery is automatic.
    } catch {
        // Keep your app usable. Retry identify() after authentication/connectivity recovers.
        print("Kirora identification failed: \(error)")
    }
}
```

Here, `kirora` is the retained instance: the app delegate's `kirora` property or
`MyApp.kirora` in the SwiftUI example. Creating a client alone does not sign the user in.

## Usage

### Identify users

Call `identify()` once the user is signed in, **and at every start while they are**. Only
then are events sent, as that user:

```swift
try await kirora.identify()             // asks fetchUserToken for a token
try await kirora.identify(token)        // or pass one you already have
```

When Kirora refuses an expired token, the SDK asks `fetchUserToken` for a fresh one and
repeats the call once. A refreshed token must name the same user. `identify()` can throw
`UserTokenError` if `fetchUserToken` fails, `KiroraApiError` (401) if Kirora refuses the
token after a refresh attempt, or `KiroraError` if no token source is configured.
With push disabled, `identify(token)` installs the token locally; validation happens
when an authenticated request is sent, so success does not confirm server acceptance.

Before your own sign-out, call `logout()`. It sends what waits, detaches the device from
the user's pushes, and forgets the user:

```swift
await kirora.logout()
```

It never throws, and takes 5 seconds at most in all, a pending `identify()` included: a
sign-in still waiting for its token when the 5 seconds run out is abandoned, so its token
can't sign the user back in. If Kirora can't be reached, the SDK keeps trying to detach the device in the background, as it retries events (30
seconds, doubling to 5 minutes), until someone signs in, the client is destroyed, or a day
has passed.

Events tracked before `identify()` wait on the device and go as the next user to sign in.
Nothing is ever sent anonymously.

### Track events

```swift
kirora.track("Order Completed", properties: [
    "order_id": "1042",
    "total": 46.5,
    "currency": "USD",
])
```

`track()` returns at once and never throws. Properties are copied as they are when you
call it, and must be JSON: strings, numbers, booleans, `nil`/`NSNull`, arrays and
dictionaries of them. Dates are sent as ISO 8601 strings, and URLs and UUIDs as strings.
Unsupported dictionary values are left out and logged; unsupported array elements become
JSON `null`. Non-finite numbers (`NaN` and infinity) also become `null`.

### Screen views

Screens are never tracked automatically: platforms name screens too differently. Track
them yourself, with your own names:

```swift
kirora.trackScreenView("Checkout")      // tracks Screen Viewed { name: "Checkout" }
```

In SwiftUI, `.onAppear { kirora.trackScreenView("Checkout") }`; in UIKit, a view
controller's `viewDidAppear(_:)`.

### Sessions

A visit begins with `Session Started` and ends after 30 minutes without activity. Each
event carries the visit in `context.sessionId`. Time in the foreground never ends a visit,
and a relaunch within 30 minutes continues it. Turn it off with `trackSessions: false`.

### App lifecycle

With `trackAppLifecycle: true`, the SDK tracks `Application Installed` (first launch),
`Application Updated` (first launch of a new version), `Application Opened` (each launch
and return to the foreground, with `from_background`) and `Application Backgrounded`.
Installed, updated and opened events carry your app's `version` and `build`;
`Application Backgrounded` currently has empty properties. Off by default.

### Tracking consent

If event tracking needs opt-in, set `requireTrackingConsent: true`. Events, session ids
and the event-tracking device id are not created until the user agrees:

```swift
let kirora = Kirora(options: KiroraOptions(clientKey: "kirora_pk_…", requireTrackingConsent: true))

// When the user answers:
kirora.setTrackingConsent(true)
```

The answer is remembered on the device. `setTrackingConsent(false)` also forgets queued
events, the visit, and the device id unless a push registration still needs it. A retained
id is removed by logout cleanup when the device is no longer registered.

Tracking consent, notification permission and marketing push consent are separate
controls. Push registration and reporting do not use the event tracking consent gate. With push
off and consent required, nothing at all is stored before consent but the answer itself.

## Push notifications

### Set up your app

1. In Xcode, add the **Push Notifications** capability to your app target.
2. In the Kirora dashboard, add an iOS push app with your APNs key (`.p8`), key id, team
   id and bundle id. If you already send to iOS through Firebase, give it your Firebase
   service account instead (see [Sending through Firebase](#sending-through-firebase)).
3. Turn push on when you create the client:

```swift
let kirora = Kirora(options: KiroraOptions(
    clientKey: "kirora_pk_…",
    fetchUserToken: { try await MyAPI.kiroraToken() },
    push: .enabled
))
```

4. Ask for permission at a moment that makes sense to the user, e.g. after they turn on
   order updates:

```swift
let permission = await kirora.requestPushPermission()   // .granted, .denied, .unanswered or .unsupported
```

That's all. The SDK registers the device with Kirora at `identify()` once the user has
allowed notifications, and again only when the user, the APNs token or the day changes.
If the user turns notifications off in Settings, the SDK tells Kirora the next time the
app comes to the foreground.

Only if your workspace has more than one iOS push app, name the one to use:
`push: PushOptions(pushAppId: "…")`.

### Sending through Firebase

If your iOS push app in Kirora uses a Firebase service account, Kirora tells the SDK to
register Firebase's token instead of the APNs one. Add FirebaseMessaging to your app and
configure Firebase as usual (`FirebaseApp.configure()`, with your APNs key uploaded to
Firebase). The SDK reads the token from FirebaseMessaging at runtime and registers again
whenever Firebase makes a new one: it never links Firebase itself, so apps without it carry
none of it. Pushes, taps and deliveries work the same either way.

### Marketing consent

The notification permission alone doesn't allow marketing pushes. Record the user's own
answer when you ask them:

```swift
try await kirora.setPushConsent(true)
```

### Taps and links

The SDK reports taps on Kirora pushes and opens their link, with no code in your app:

- A web link goes to your app as a universal link: to your scene delegate's
  `scene(_:continue:)` in a scene-based app (SwiftUI's `onContinueUserActivity` included),
  or your app delegate's `application(_:continue:restorationHandler:)`.
- Any other link, including an app link like `myapp://orders/1`, is opened with
  `UIApplication.open`.

To route links yourself, set `handleDeepLink`. It's called on the main thread; return
`true` if you opened the link, or `false` to let the SDK open it as above:

```swift
let kirora = Kirora(options: KiroraOptions(
    clientKey: "kirora_pk_…",
    push: .enabled,
    handleDeepLink: { url in
        guard url.host == "shop.example" else { return false }
        Router.shared.open(url)
        return true
    }
))
```

Kirora pushes are shown while your app is open, unless your own
`UNUserNotificationCenterDelegate` decides otherwise. Your delegate keeps working as
before: the SDK passes every call on to it, whenever you set it.

#### Without the automatic integration

The SDK picks up the APNs token by adding itself to your app delegate's callbacks, and
taps by wrapping `UNUserNotificationCenter`'s delegate, as Firebase does. To turn that
off, set `KiroraAppDelegateProxyEnabled` to `NO` (Boolean) in your Info.plist, and forward
the callbacks yourself:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Kirora.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
}

func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Kirora.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
}

func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    if Kirora.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler) { return }
    // Not a Kirora push: handle it, then call completionHandler().
}

func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if Kirora.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler) { return }
    completionHandler([])
}
```

### Delivery reports and images

iOS only lets an app see a push arrive, or show its image, from a **Notification Service
Extension**. Without one, Kirora's reports leave iOS out of the delivered rate, and pushes
show without images.

1. In Xcode, **File → New → Target… → Notification Service Extension**.
2. Add the **KiroraNotificationService** library to the extension target.
3. Replace the generated `NotificationService.swift` with:

```swift
import KiroraNotificationService

class NotificationService: KiroraNotificationServiceExtension {}
```

The extension attempts a delivery report and downloads the image before handing the
notification to iOS. These reports are best effort: a network error, `429` or `5xx` is
retried once, then dropped. A dashboard test push without `trackingUrl` sends no report.
If you have your own extension already, call the helper from it instead:

```swift
override func didReceive(_ request: UNNotificationRequest,
                         withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    if KiroraNotificationService.didReceive(request, withContentHandler: contentHandler) { return }
    // Not a Kirora push: your own handling.
}

override func serviceExtensionTimeWillExpire() {
    KiroraNotificationService.serviceExtensionTimeWillExpire()
}
```

The extension needs no client key and no App Group: each push carries its own reporting
address. Keep its generated `NSExtension` configuration and principal class pointing at
your `NotificationService` subclass, and set the extension's deployment target to match
the app. Kirora supplies `mutable-content: 1`; custom payloads must include it to invoke
the extension. Test images and delivery reports with the app in the background as well
as the foreground.

A push is Kirora's only when it says so: the top-level `kirora` marker, or a
`trackingUrl` at Kirora's tracking path. Another provider's push that happens to use
`actionUrl` or `imageUrl` is left to your app and its extension code. Links with
`javascript:`, `data:`, `file:` or `vbscript:` schemes are never opened.

## API

### `Kirora(options:)`

| Option | Default | |
| --- | --- | --- |
| `clientKey` | required | The workspace's public key, `kirora_pk_…` |
| `fetchUserToken` | `nil` | `() async throws -> String`: asks your server for a user token. Called by `identify()` without a token, and when Kirora refuses an expired one. One that hasn't answered after 30 seconds counts as failed |
| `push` | `nil` (off) | `.enabled`, or `PushOptions(pushAppId:)` |
| `requireTrackingConsent` | `false` | Gate events and sessions on `setTrackingConsent(true)`; see [Tracking consent](#tracking-consent) for push and storage behavior |
| `trackSessions` | `true` | `Session Started` when a visit begins, `context.sessionId` on every event |
| `trackAppLifecycle` | `false` | The `Application …` events |
| `handleDeepLink` | `nil` | `(URL) -> Bool`, on the main thread: a tapped push's link; `true` when your app opened it itself |
| `logLevel` | `.error` | `.none`, `.error` or `.debug` (event names and delivery counts; unified log subsystem `io.kirora.sdk`) |
| `apiUrl` | `https://api.kirora.io` | Staging or a private deployment |

### Methods

| Method | Answers | Does |
| --- | --- | --- |
| `identify(_ userToken: String? = nil) async throws` | | Signs the user in, registers the device for push if allowed, sends waiting events |
| `logout() async` | | Sends what waits and detaches the device, for 5 seconds at most in all (a pending `identify()` included), then forgets the user and their unsent events. Never fails. See [Identify users](#identify-users) for retries |
| `track(_ name:, properties:)` | at once | Queues an event; never throws |
| `trackScreenView(_ name:)` | at once | `Screen Viewed` |
| `setTrackingConsent(_ granted:)` | | The user's answer, remembered on the device |
| `requestPushPermission() async` | `PushPermission` | iOS's prompt, then registration if granted |
| `setPushConsent(_ granted:) async throws` | | Consent to marketing push, recorded with proof |
| `flush() async` | | Attempts event delivery; returning does not guarantee acceptance. Also schedules pending app-open reports |
| `destroy()` | | Stops the client's timers and observers, without sending or deleting anything. Events still waiting stay for the next client |

### Errors

- `KiroraApiError` (`status`, `code`, `message`, `retryAfterMs`): Kirora refused a call.
- `UserTokenError` (`underlying`): `fetchUserToken` failed or timed out.
- `KiroraError` (`message`): no token to sign in with, or an `apiUrl` that isn't an address.

None is thrown by `track()`: an event Kirora refuses is logged.

## How it works

- **Batching.** Events go at once when 20 wait, otherwise every 30 seconds, when the app
  goes to the background (with time asked from iOS to finish) and when the network comes
  back. Batches hold up to 100 events.
- **Offline delivery.** Up to 1,000 events are kept on disk across restarts; past that,
  the oldest are dropped. Failed requests are retried with doubling gaps up to 5 minutes,
  never sooner than `Retry-After`. Each event gets an idempotency key when it's tracked,
  for server deduplication. Acknowledged events and permanent refusals are removed;
  unacknowledged events wait for retry. Logout, consent withdrawal and queue overflow
  also remove events. Writes are asynchronous, so an abrupt termination can lose recent
  changes; delivery is not guaranteed.
- **Users stay apart.** An event tracked while a user is signed in is only ever sent as
  that user, even if another signs in before it's sent.
- **Event context.** Each event carries `context.device.id`, `context.sessionId` (when
  sessions are enabled),
  `context.locale` (the user's language, `en-GB`) and `context.timezone`
  (`Africa/Lagos`). Kirora adds the IP address and user agent itself.
- **Clock skew.** Each batch says when it was sent, so Kirora corrects event times for a
  device whose clock is wrong.
- **Failure handling.** `track()` does not throw, and no answer from Kirora can break
  your app: network failures are retried, never sooner than `Retry-After` (an absurd one
  is cut to a week), and terminal refusals are logged.

## Privacy

To report how push notifications perform, the SDK sends:

- the app's version, the OS version, and the device's language and time zone, when it
  registers the device;
- the time the app is opened or returns to the foreground;
- when a Kirora notification is shown or tapped.

It never sends hardware or advertising identifiers. The device id is a random value the
SDK creates and keeps in the app's own storage; it is deleted with the app.

The SDK uses no IDFA, IDFV or Keychain and does not request App Tracking Transparency
permission. Both libraries include `PrivacyInfo.xcprivacy`: the main SDK declares product
interaction, user id and device id collection; the extension declares product interaction
for delivery reporting. The manifests mark this data as linked to the user and not used
for tracking. The main SDK's product interaction purposes include app functionality,
analytics and product personalization.

App-open reporting is separate from `Application Opened` events. For a signed-in user
with a push registration, it reports at most once per 30-minute visit, even when
`trackAppLifecycle` is `false`. Up to 50 pending app opens are stored per workspace;
reports older than seven days are dropped.

### What the SDK stores

Everything is in `Application Support/io.kirora.sdk/`, in your app's own container and
left out of device backups, so a restored phone gets a new device id. All of it is
deleted with the app.

| File | Holds | Removed |
| --- | --- | --- |
| `events-<hash>.json` | Events waiting to be sent, per workspace | Once Kirora answers for them; the user's at `logout()`; all on consent withdrawal |
| `state.json`, `device-id` | `device.id`: a random UUID | On consent withdrawal if no push registration remains; otherwise logout cleanup can remove it after detachment |
| `state.json`, `session` | The visit's id and last activity | On consent withdrawal |
| `state.json`, `tracking-consent` | The user's tracking consent answer | Never; it's their answer |
| `state.json`, `app-version` | The app's version and build at the last launch, for lifecycle events | |
| `state.json`, `app-open-activity` | Last app-open visit activity; only with push on | Overwritten on later lifecycle activity |
| `state.json`, `app-opens:…` | App opens waiting to be reported, per workspace | After reporting, at logout for that user, or when older than seven days during delivery |
| `state.json`, `apns-token` | Last APNs token | Overwritten when refreshed; not cleared by logout |
| `state.json`, `push-registration:…` | User, push app, token and registration time, per workspace | After successful detachment; retained if detachment fails |
| Memory only | User token | Active identity is cleared at logout; detachment work can retain the old token until it finishes or stops |

Queue files and push records are namespaced by client key and API host. Device id,
tracking consent and session state are shared within the app. Use one client per app;
independent clients writing the same files are not coordinated.

## Naming events

Segments, journeys and goals match event names exactly, so keep them consistent:

- Use an object followed by a past-tense action, in Title Case: `Plan Upgraded`,
  `Invoice Paid`, `Signup Started`.
- Name what the user did, not where: `Order Completed` with `["source": "checkout"]`,
  not `Checkout Screen Button Tapped`.
- Put details in properties: `Plan Upgraded` with `["plan": "pro"]`, not
  `Pro Plan Upgraded`.
- Use the standard e-commerce names where they apply: `Product Viewed`, `Product Added`,
  `Order Completed` and so on.
- Names starting with `contact.` are reserved.

## Verify your integration

1. Request your token route signed out: expect `401`. Signed in, expect a plain-text JWT
   for the session user.
2. Temporarily set `logLevel: .debug`, identify a signed-in user and track an event. In
   Console.app, filter on subsystem `io.kirora.sdk` and look for `Kirora: Sent … events`
   within 30 seconds or after sending the app to the background. Debug logs include event
   names; remove the setting after checking.
3. If consent is required, check no events are sent before the user agrees, and that
   withdrawing consent clears the event queue. Push is separate: see
   [Tracking consent](#tracking-consent).
4. For push, run on a device (or a simulator on iOS 16+ with Apple silicon), allow
   notifications, and send a test push from the dashboard.
5. Use a regular campaign push to verify delivery and tap reports; dashboard test sends
   without `trackingUrl` cannot verify reporting. Check foreground display, a cold-start
   tap, image attachments, notification permission changes in Settings and logout offline.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Events stay queued | Call `identify()` at every start while signed in; check tracking consent, connectivity and your token route. |
| Token fails, or Kirora answers `401` | Sign with the workspace's token secret, the session user's id as `sub`, and an unexpired token valid for at most 24 hours. |
| "iOS gave no APNs token" | Add the Push Notifications capability, and check the provisioning profile includes it. |
| "This push app sends through Firebase, but the app has no Firebase token" | Add FirebaseMessaging, call `FirebaseApp.configure()`, and upload your APNs key to Firebase. |
| "No ready iOS push app" | Add an iOS push app with a valid APNs key in the dashboard, or check `pushAppId`. |
| Taps aren't reported, or links don't open | If `KiroraAppDelegateProxyEnabled` is `NO`, forward the callbacks as in [Without the automatic integration](#without-the-automatic-integration). |
| No delivered counts, or no images | Add the [Notification Service Extension](#delivery-reports-and-images). |

## Support and contributing

For integration help, email [support@kirora.io](mailto:support@kirora.io). See
[CONTRIBUTING.md](CONTRIBUTING.md) for local development, and [SECURITY.md](SECURITY.md)
to report vulnerabilities privately.

## License

MIT. See [LICENSE](LICENSE).
