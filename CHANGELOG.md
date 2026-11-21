# Kirora iOS SDK

## Unreleased

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

## 0.1.0

First release: event tracking, sessions, screen views, app lifecycle events, tracking
consent and push (registration, taps, app opens, and deliveries and images from a
Notification Service Extension).
