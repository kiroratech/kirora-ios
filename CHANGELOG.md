# Kirora iOS SDK

## 0.1.0 (2026-11-23)

First release: event tracking, sessions, screen views, app lifecycle events, tracking
consent and push (registration, taps, app opens, and deliveries, images and buttons from
a Notification Service Extension).

### Changes during pre-release development

- The event queue file is written at most once a second, and at once as the app goes to
  the background, rather than after every event: each write holds the whole queue (up to
  1 MB). A crash can lose up to the last second of events.
- Push: when the SDK adds the APNs token callbacks to an app delegate that lacks them,
  it sets the delegate again, so UIKit sees them (as Firebase does). Before, such an app
  could get no token and never register.
- Push: coming back online registers a device whose registration failed offline (no
  APNs or Firebase token yet, or no answer from Kirora). Before, it waited until the app
  next came to the foreground.
- Push: an app in Firebase's installation-ID mode (FirebaseMessaging 12.16+,
  `FirebaseMessagingInstallationIdEnabled` = `YES`), which has no FCM token, registers its
  Firebase installation ID (`targetKind: "firebase_installation_id"`). Before, it never
  registered.
- Fix: a new Firebase token registers the device again at once. The SDK listened for a
  notification name Firebase no longer posts, so a token Firebase changed while the app
  ran went unregistered until the next launch.
- The background flush writes the client's event file without holding a thread, and no longer waits on every Kirora file in the process.
- Fix: during `logout()`, a sign-in already under way adopted events tracked during the
  logout, an `identify()` made during it adopted the outgoing user's waiting events, and
  two overlapping logouts could leave a user signed in. Waiting events are now held for
  the sign-in under way as the logout began, and logouts run one after another.
- Fix: a refusal every event met (a field Kirora stopped taking) split batches down to one
  event over and over with no delay, sending thousands of requests and emptying the queue.
  After one event is refused alone, another refusal now waits for the backoff.
- Fix: a tap on a push that replaced an earlier one with the same collapse id was ignored
  as already handled; a tap on one of the app's own notification actions was reported as
  an open; and the extension could lose track of two such pushes handled at once.
- `track()` no longer waits behind a read of the events file while a sign-in or logout
  adopts or clears waiting events.
- Fix: an `identify()` made while `logout()` waited for a sign-in under way was signed
  out by that logout, or abandoned with it if that wait ran out; with nobody signed in as
  the logout began, its push registration was also detached. A logout now signs out only
  sign-ins made before it, and events tracked once it begins wait for the next user.
- Fix: once Kirora refused a token with no `fetchUserToken` to replace it, only events
  stopped; app opens, push registration and `setPushConsent(_:)` kept trying as that user.
  Now every request as that user waits for `identify()` with a new token
  (`setPushConsent(_:)` throws the 401). Detaching goes on with the device secret.
- Fix: signing out after a relaunch, before `identify()`, left the device registered to the
  user, so their pushes kept arriving. The SDK now makes a device secret once per
  installation (32 random bytes, kept with the device id) and sends it with every push
  registration; it can only detach the device. `logout()` with nobody signed in detaches
  by it, as does a detachment whose user token Kirora refused. A detachment still
  pending as the app ends continues at the next launch, within 24 hours of the sign-out.
  `setPushEnabled(false)` with nobody signed in detaches the same way.
- Fix: events tracked before `identify()` by an app that restored its own session after a
  relaunch were taken by the next user to sign in. `logout()` now drops the waiting events
  the signing-out user made: with a user signed in, all those waiting as it began; with
  nobody signed in, those that continued a signed-in user's visit. A visitor who never
  signed in keeps theirs. Call `identify()` at every launch while the app is signed in,
  and `logout()` only from the app's sign-out.
- Fix: signing out could leave the device registered to the user, so their pushes kept
  arriving. The device's id was dropped when tracking was refused during a registration,
  and signing out then detached a different id. A registration now keeps the id it was
  made with, and a detachment still waiting is retried as the app goes to the background
  (with time from iOS) and comes back.
- Fix: after a relaunch, events tracked before sign-in joined the previous user's visit,
  and kept its `sessionId` when a different user signed in and took them. They're now
  sent without one, as the spec and web do; the same user signing in again keeps them in
  their visit.
- Fix: two threads making the device id at once on a fresh install could make two.
- Fix: an event tracked at the instant of sign-in could be left for the next user to send.
- Fix: after the device slept, new events could wait for an older retry timer instead of
  going within 30 seconds.
- Fix: saved state that failed to encode removed the file, as if empty; it's now kept.
- Fix: in the Notification Service Extension, one push running out of time cut short the
  others the process was working on: `serviceExtensionTimeWillExpire(for:)` ends only its
  own (`KiroraNotificationServiceExtension` uses it). A slow delivery report holds a push
  back 5 seconds at most, not up to 20.
- Fix: a client made off the main thread and destroyed at once left its lifecycle observers
  and timer running; an app-open send asked for during another could wait until the next
  foreground; asking iOS for background time could deadlock if it had none left.
- `PushOptions` is now `KiroraPushOptions`, the name every Kirora SDK uses.
- `fetchUserToken` may return no token: it's `async throws -> String?`. `nil` or empty is a
  failed fetch, as a throw is: `identify()` throws `UserTokenError` ("fetchUserToken
  returned no token"), a background refresh tells `onAuthenticationFailed` `.fetchFailed`
  once the token has expired, and nothing is sent with an empty token. A wrapper's
  `TokenRequests.answer(_:token:)` takes `nil` the same way.
- A refreshed token without `sub` is refused, as one naming another user is: it can't be
  told from another user's. `onAuthenticationFailed` hears `.refused`.
- A device clock that's off no longer costs a refused request per token. A token already
  expired as it arrives, or whose `iat` is more than 60 seconds ahead of the device's
  clock, has its lifetime (`exp` less `iat`) counted from now, so it's refreshed 60 seconds
  before it runs out, as on any device. Before, an expired-looking token was fetched again
  at once at sign-in, and later ones were replaced only after Kirora refused them. A stale
  token passed to `identify()` is now replaced once Kirora refuses it.
- A `422` is split per event only when its `errors` name a body field under `events`, as a
  `400` is. One naming no event (a proxy answering `422` to everything, a wrong `apiUrl`)
  keeps the events and backs off, instead of dropping the queue one event at a time.
- `trackingConsent`: whether tracking is allowed now, as `getState().trackingConsent`,
  without reading the event queue.
- Fix: foreground Kirora pushes were dropped when the app's notification delegate, or a
  library in its chain (`flutter_local_notifications`, `firebase_messaging`), ignored them
  or answered `[]` for pushes it didn't make. The SDK now answers `willPresent` for Kirora's
  pushes before the app's delegate, which no longer decides on them; wrapper apps decide
  through the wrapper's foreground handler. A Kirora tap a delegate leaves unanswered has
  its completion handler called after 1.5 seconds.
- Fix: a notification delegate that keeps the one it found and passes calls on to it
  (`firebase_messaging` does), set after the SDK's, no longer loops with it until the app
  crashes on a tap or another library's push in the foreground. Calls it passes back go on
  to the delegate before it.
- Fix: a push's web link was swallowed in Flutter and React Native apps, whose app delegates
  say they handled any web link. A link nobody claims now opens with iOS (the browser, or
  the app that owns it); only hosts the app lists in `KiroraUniversalLinkHosts` go to its
  app delegate as universal links. A native app that kept its universal links in the app
  through its delegate lists their hosts, or claims them in `handleDeepLink`.
- Push buttons show: the Notification Service Extension makes a category from the push's
  `buttons` and adds it to the app's own. Without the extension, still none.
- `Kirora.addNotificationClickListener(_:)`: hears taps on Kirora pushes and their buttons,
  with the push's data, on the main thread; taps from before any listener (the latest ten)
  go to the first one. `KiroraPushTap` is public.
- A user token is refreshed 60 seconds before its `exp`, and on returning to the foreground
  after it expired, not only after a `401`. An expired token that can't be refreshed is told
  to `onAuthenticationFailed` as `.fetchFailed`.
- A `401` that no fresh token resolves backs off (with `fetchUserToken`) or stops sending
  until the next `identify()` (without), instead of retrying and asking for a token at every
  send.
- A whole-request refusal no event caused (a redirect, `403`, `404`, `409`, or a `400` about
  a header) keeps the events and backs off, instead of dropping them: a wrong `apiUrl` or a
  captive portal could empty the queue. A `400` is split to find the event at fault only when
  its `errors` name a field under `events`.
- Push reports go only to a `/t/p/…` address on the configured `apiUrl` (under its path, if
  it has one); a tap heard before any client exists waits for one, 10 seconds at most. The extension uses
  `https://api.kirora.io`, or its own `KiroraApiUrl` Info.plist key.
- Wrappers: `setSDK` takes only `kirora-react-native` and `kirora-flutter`, with a version
  Kirora accepts (`[0-9A-Za-z.+-]{1,40}`); anything else is ignored and logged.

- `onAuthenticationFailed`: called on the main thread with `.fetchFailed` or `.refused`
  when the user's token fails in the background, where no method would throw it; not for
  work `identify()` started that fails as `identify()` itself throws.
- CocoaPods: `Kirora` and `KiroraNotificationService` pods, beside Swift Package Manager.
- For the React Native and Flutter SDKs, which wrap this one (`@_spi(Wrapper)`, not for
  apps): their own `Kirora-SDK` name, `fetchUserToken` answered across the bridge, a tap
  listener that holds the latest ten taps until it's attached, and `handleDeepLink` and
  foreground display asked across the bridge for 1.5 seconds at most, and
  `installPushIntegration()` so the tap that launched the app is heard before the client
  exists, its link waiting (10 seconds at most) until the wrapper's deep-link handler is set
  up.

- Clarify installation targets, client retention, token fetching and first-event setup.
- Document consent boundaries, storage retention and best-effort push reporting.
- Fix issues found in review:
  - Storage that can't be read at launch (before the first unlock) is read again once it
    can, and merged with what happened meanwhile, so tracking no longer stays off for the
    rest of the session; push registration waits for it. Events tracked before the first
    read can no longer overwrite such a file.
  - An event whose `beforeSend` was still running when its user signed out, or when
    consent was withdrawn, is dropped with the rest; one from before sign-in goes to the
    user who signed in meanwhile.
  - `track("")` is refused and logged, as on web, instead of being sent.
  - A batch result that isn't Kirora's accepted or refused shape no longer clears its
    event; it's retried.
  - `getState().pushToken` is only the signed-in user's current registration's token.
  - A detach never refreshes the outgoing user's token: a 401 ends it.
  - Web links from a push are no longer handed to a scene delegate, which can't say
    whether it opened them: unclaimed ones open with iOS. Scene-based apps claim their
    own universal links in `handleDeepLink`.
  - Lifecycle events are handled off the main thread, so launch never waits for the files.
  - With `trackSessions: false`, app-open spacing is kept in memory only.
  - Events cleared, or a value removed, while storage couldn't be read stay gone once it
    can be; a flush cancelled at logout no longer returns before the send it was asked for;
    a logout during a retried detach no longer starts a second one.
- Follow the 17 November client SDK interface: a tracking refusal is also kept in a file of
  its own, `consent.json`. When the saved answer can't be read, an app without
  `requireTrackingConsent` tracks as on a fresh install unless a refusal is on record
  (nothing while neither file can be read); with it, nothing until a fresh answer.
  - An oversized `Retry-After` can no longer crash the app.
  - Nothing is stored before tracking consent with push off.
  - `logout()` takes 5 seconds at most in all, a pending `identify()` included.
  - Starting the client no longer reads the disk on the calling thread.
  - `destroy()` during a detachment stops its retries.
  - Only pushes carrying Kirora's `kirora` marker are handled.
- Document how long Kirora keeps an unseen device, and that transactional pushes need
  only the notification permission.
- Follow the 14 and 16 November client SDK interface:
  - New `getPushStatus()` and `setPushEnabled(_:)`, for an app's own notifications setting.
  - New `beforeSend` option, to redact or drop events before they're stored.
  - New `getState()`, a read-only snapshot for support and debug screens.
  - Event `context` carries `app`, `os`, `screen` and `device.manufacturer`/`type`, in
    Segment's names, as Kirora now accepts them. No device model.
  - Every error is a `KiroraError`: `KiroraApiError` and `UserTokenError` are now subclasses
    of it, and a call that can't reach Kirora throws `KiroraError` with the network's error
    as `underlying`. `UserTokenError.underlying` is now optional, as it's the base's.
  - `identify()` throws `KiroraError` for an `apiUrl` that isn't an address, and
    `setPushConsent(_:)` throws whenever Kirora hasn't recorded the choice.
  - App opens for push reports now need tracking consent; withdrawing it drops waiting ones.
  - Events from before sign-in become the signing-in user's, and never go as a later user.
    What's tracked while `logout()` runs waits for the next user.
  - A visit belongs to its user: logout ends it, and a new user begins their own.
  - An event holding values JSON can't hold faithfully (`NaN`, infinity, unsupported
    objects) is dropped instead of sent changed; a `nil` member is left out, not `null`.
  - Events Kirora refuses for now (`RATE_LIMITED`, `INTERNAL_ERROR`,
    `SERVICE_UNAVAILABLE`) are retried instead of dropped.
  - The queue also keeps at most 1,000,000 bytes.
  - Another user's sign-in no longer cancels the detachment of a signed-out user's device;
    only a successful registration that takes the device over ends it.
  - Device id, visit, consent and app state are kept per workspace.
  - A saved consent answer that can't be read no longer falls back to the default.
  - A tapped notification button opens its link.
  - Withdrawing tracking consent cancels a send under way; `logout()` cancels a request
    still running at its 5-second deadline (the detachment is then retried).
  - When events can't be saved, the SDK says so once: they're kept in memory, within the
    same limits, and won't survive a restart.
  - Every detachment (`logout()`, `setPushEnabled(false)`) names the device's last
    registration (`DELETE /devices/{id}?lastSeenAt=`), so a late retry can't undo a newer
    sign-in; Kirora's answer (204, 409, another 4xx) ends it, not the device. The
    registration record, and the device id, are kept until Kirora confirms.
  - Clients in one app share one copy of each file, so two workspaces' clients no longer
    overwrite each other's saved state, and two clients never adopt the same events.
