# Kirora iOS SDK review

**Reviewed:** 17 November 2026.  
**Repository:** `kirora/kirora-ios` (the requested `kirora/ios-sdk` path does not exist).  
**Snapshot:** `HEAD d179485` plus the current tracked modifications and untracked SDK source/podspecs. Concurrent wrapper teardown additions were included in the final build refresh.  
**Contract:** `../../omnichannel/docs/sdk-interface.md`, including the 17 November consent-storage rules and current wrapper teardown contract.  
**Verdict:** **Request changes before declaring full SDK conformance or production readiness.** Since resolved: see "Resolution" below.

The SDK has a strong, deliberately small foundation: no third-party dependencies, explicit event ownership, bounded storage, pre-storage redaction, separate consent controls and an independent notification extension. The remaining problems are concentrated in acknowledgement validation, diagnostic push state, cleanup authentication, startup I/O and link routing. Six findings follow; five were reproduced with isolated probes, while the UIKit link-routing finding is supported by a concrete source path and Apple's API contract.

This task changes documentation only. The README was rewritten to describe actual behaviour and limitations. No SDK implementation or test-suite changes were made, and the suite was not run. Historical reviews below are retained for context; their old “all fixed” conclusions do not establish the current snapshot's conformance.

## Resolution (17 November 2026)

All six findings are fixed in the working tree (uncommitted), each with tests that fail
without the fix. 174 tests pass in repeated runs; the strict-concurrency build and the Mac
Catalyst UIKit typecheck are clean. Nothing has run on a device. The README's "Current
limitations" section is gone, its points replaced by the behaviour below.

| ID | Resolution | Tests |
| --- | --- | --- |
| IOS-01 | An event is acknowledged only by Kirora's own shapes: accepted is an `event` object with no `error`; refused is an `error` object with a non-empty string `code` and no `event`. A key alone, a scalar or empty error, a scalar event, or both at once settle nothing: the event stays, payload and key unchanged, for a retry after the backoff. The fake server's success answers now carry `event`, as the server's `TrackEventsBatchResult` does. | `anUnreadableResultKeepsTheEvent` (6 shapes) |
| IOS-02 | `getState().pushToken` applies `getPushStatus()`'s checks short of asking iOS: the signed-in user's own, non-detaching, granted registration for this device, not failed, push not turned off. It reads the device id without making one. | `aRestartBeforeSignInShowsNoToken`, `aSwitchWhoseRegistrationFailedShowsNoToken`, `pushTurnedOffShowsNoToken` |
| IOS-03 | Detach requests use the captured token with refreshing off: a `401` is a terminal refusal, and `fetchUserToken` isn't called. Other requests still refresh once. | `aDetachNeverRefreshesTheToken` |
| IOS-04 | Decided with the user: a scene delegate is never handed a web link, as `scene(_:continue:)` can't report whether it took it. A web link stays in the app only if the app delegate's `application(_:continue:restorationHandler:)` returns `true`; otherwise it opens with `UIApplication.open`. Scene-based apps claim their own universal links in `handleDeepLink`. The spec's "iOS → Links" change was sent to the omnichannel session. | Mac Catalyst typecheck only; needs a device check |
| IOS-05 | The UIKit lifecycle source hands events to a serial queue off the main thread, in order; `.background` runs there under background time. Creating the client no longer waits on a busy state file even when UIKit sends `.launched` from inside `start`. | `aSlowStateFileNeverHoldsUpTheAppAtLaunch` |
| IOS-06 | With `trackSessions: false`, app-open spacing is kept in memory only; with visits on, it's saved as before. Consent withdrawal clears both. | `withVisitsOffTheSpacingIsntSaved`, `withVisitsOnTheSpacingIsSavedWithThem` |

## Findings

| ID | Priority | Finding | Evidence |
| --- | --- | --- | --- |
| IOS-01 | P1 | Malformed per-event results can silently remove unacknowledged events | Isolated fake-transport probe |
| IOS-02 | P2 | `getState().pushToken` can report another session's cached registration | Restart and failed-transfer probes |
| IOS-03 | P2 | Detachment refreshes credentials that the contract says to retain unchanged | Isolated logout/401 probe |
| IOS-04 | P2 | An external HTTPS push link can be swallowed by a scene handler | UIKit source path and Apple reference |
| IOS-05 | P2 | Automatic launch handling can synchronously wait on state-file I/O | Isolated delayed-storage/lifecycle probe |
| IOS-06 | P3 | Session-disabled app-open spacing is persisted instead of kept in memory | Isolated lifecycle/storage probe |

P1 denotes a high-impact correctness failure requiring correction before release. P2 denotes required correctness or integration work. P3 is a smaller explicit contract mismatch, not evidence of cross-app tracking or a severe security vulnerability.

### IOS-01 — Validate the result before acknowledging its event

**Locations:** [EventDelivery.swift:225](../Sources/Kirora/Internal/EventDelivery.swift#L225), especially `acknowledgedKeys`; [ClientAPI.swift:139](../Sources/Kirora/Internal/ClientAPI.swift#L139). Contract: **Event capture and delivery → Acknowledgements**.

The code correctly rejects duplicate keys, ignores unknown keys and retries the three transient error codes. It does not establish that a result is a readable success or a readable terminal error before removing the event. A missing/null `error` is accepted as success; an existing but malformed `error` is treated as a terminal refusal because its code is not in the transient set.

**Reproduction:** queue one event and return HTTP 200 with:

```json
{
  "data": {
    "results": [
      { "idempotencyKey": "<the requested key>", "error": "unreadable" }
    ]
  }
}
```

The actual queue count changed from **1 to 0**. Nothing in this response confirms acceptance or gives a usable terminal error. A matching key alone is insufficient. An empty result object carrying only the key has the same structural problem.

The server's current result schema is a union of a recorded event (`replayed` and `event`) and an error object (`code`, `message`, optional details). The transport's optional JSON decode also means malformed successful bodies reach delivery as absent data; those currently remain queued, which is preferable to falsely acknowledging a malformed keyed result.

**Correction:** validate each matched result against a minimal readable success/error shape before acknowledging it. Preserve malformed/ambiguous results for retry with backoff. A valid terminal refusal may still be dropped; this does not require reimplementing server business validation or retrying every future error code.

**Verification to add in a later implementation task:** key-only results, scalar/empty errors, contradictory success/error fields, duplicated keys, incomplete batches and a subsequent valid result. Verify original event payload and idempotency key survive. Existing duplicate/transient-result coverage does not establish these cases; some fake success responses also omit real success fields and should be made representative when this is fixed.

### IOS-02 — Bind diagnostic push state to the selected identity and registration outcome

**Locations:** [PushRegistrar.swift:244](../Sources/Kirora/Push/PushRegistrar.swift#L244), [PushRegistrar.swift:567](../Sources/Kirora/Push/PushRegistrar.swift#L567), [Kirora.swift:327](../Sources/Kirora/Kirora.swift#L327). Contract: **Methods → getState**.

`registeredToken` returns the cached record's token when it is not marked detaching. It does not require a selected user, matching record owner or successful current registration. `getPushStatus()` performs more of these checks, so the two diagnostics can disagree.

**Reproduced:** register A successfully, destroy the client and recreate it using the same store without identifying anyone. The new snapshot reported:

```text
restart_identified=false, restart_pushToken=abcd01
```

Then select B while making registration fail with 503:

```text
failed_transfer_pushToken=abcd01, push_status=disabled
```

The contract explicitly requires a null token before sign-in and after failed registration. The current fresh-store state test does not cover restoring a record from a previous client.

**Impact:** support screens and wrappers can misrepresent registration. This finding does not prove that B's events or notifications are sent with A's credentials: identity ownership and diagnostic presentation are separate questions.

**Correction:** expose a token only for an active, successful registration belonging to the currently selected identity; account for failure, device disablement and detachment. Keep `getState()` free of registration, ID creation, prompts and network calls. Cover restart, direct account switch with failed registration, permission changes and destruction.

### IOS-03 — Do not refresh a detach request through the live token callback

**Locations:** [PushRegistrar.swift:381](../Sources/Kirora/Push/PushRegistrar.swift#L381), [ClientAPI.swift:111](../Sources/Kirora/Internal/ClientAPI.swift#L111), [Identity.swift:141](../Sources/Kirora/Internal/Identity.swift#L141). Contract: **Device cleanup after sign-out**.

Cleanup calls the general authenticated request method with a `SignedInUser`. That method refreshes on 401 if the same identity is still selected. During foreground logout, the outgoing user remains selected to permit the final flush and detach, so this refresh path is reachable.

**Reproduced:** identify A with an explicit token; make the first DELETE return 401; configure `fetchUserToken` to return a new token for A. Logout invoked the callback **once** and made **two DELETE requests**.

The contract requires detachment to use the outgoing captured token, treat an expired/refused token as terminal, and avoid refreshing through a later user's callback. The subject check protects against installing a different user's refreshed token, but does not satisfy this cleanup rule. It can also unnecessarily invoke an app authentication dependency during logout.

**Correction:** give cleanup an internal request mode using its captured credential without refresh. Preserve normal refresh for event delivery and other active-user operations. Confirm 401/403 stop cleanup without calling the provider; network errors, 429 and 5xx should retain the existing bounded retries. Continue sending the last successful registration's `lastSeenAt`.

### IOS-04 — Preserve browser fallback for external links in scene-based apps

**Location:** [UIKitIntegration.swift:399](../Sources/Kirora/Push/UIKitIntegration.swift#L399), `openPushLink`. Contract: **iOS → Links**.

For every HTTP/HTTPS URL, the SDK constructs a browsing activity and calls the selected scene delegate's `scene(_:continue:)` if that method exists, then returns. It does not establish that the URL is a universal link belonging to the app. This scene method returns `Void`; method presence does not mean the app accepted the URL.

**Concrete failure path:** an app's scene delegate handles `https://app.example.com/...` and ignores other hosts. A push links to an external help page. Kirora calls the scene delegate, the app ignores it, and the unconditional return prevents `UIApplication.open` from opening the browser. The app-delegate branch checks its Boolean answer; the scene branch has no equivalent.

**Correction:** do not classify all web URLs as app-owned universal links. Preserve system opening for URLs the app has not explicitly handled, using the existing routing callback where the app needs to claim its own URLs. Test external HTTPS, app-owned universal links, custom schemes, an ignoring scene delegate and multiple scenes. Do not add a new public option without updating the shared interface first.

**Evidence limit:** source-established, not a device reproduction. Apple's [`scene(_:continue:)` reference](https://developer.apple.com/documentation/uikit/uiscenedelegate/scene(_:continue:)) confirms the callback has no handled/unhandled result. Mac Catalyst typechecking does not exercise routing in a running app.

### IOS-05 — Finish the startup I/O fix through the automatic lifecycle path

**Locations:** [UIKitIntegration.swift:17](../Sources/Kirora/Push/UIKitIntegration.swift#L17), [Kirora.swift:404](../Sources/Kirora/Kirora.swift#L404), [Tracker.swift:273](../Sources/Kirora/Internal/Tracker.swift#L273), [Storage.swift:331](../Sources/Kirora/Internal/Storage.swift#L331).

Files are initially scheduled for background reads, but the live lifecycle starts synchronously on the main thread. When the app is not backgrounded, it immediately emits `.launched`. That calls `tracker.noteActivity()`, which checks consent/session state; a value not yet loaded invokes `readNow` and `queue.sync`.

**Reproduced:** use an actual `FileKeyValueStore`, occupy its file queue for 300ms before the initial read, and use a lifecycle source that emits `.launched` synchronously like UIKit's main-thread path. Constructing the client took **373ms** in this run. The delay is an injected occupied queue, not a claim that normal devices always take this long.

The historical R4 fix moved eager reads off the initializer but did not eliminate the wait when launch immediately requests those values. The old README and changelog's absolute no-calling-thread-disk claim is therefore too strong. The rewritten README removes it.

**Correction:** sequence launch/session work after initial storage readiness without synchronously waiting on the host app's launch thread. Keep the fail-closed consent behaviour and event ordering. Verify initialization using the production lifecycle ordering plus a slow/unreadable file, rather than only constructing an idle fake lifecycle.

### IOS-06 — Keep app-open spacing in memory when sessions are disabled

**Locations:** [AppOpens.swift:75](../Sources/Kirora/Push/AppOpens.swift#L75), [AppOpens.swift:194](../Sources/Kirora/Push/AppOpens.swift#L194). Contract: **Push reporting → App opens → When**.

The contract explicitly says that with `trackSessions` off, spacing is kept in memory without a session event. `AppOpens` has no session-mode input and always stores `app-open-activity` through the workspace store.

**Reproduced:** enable push, disable session tracking, identify A and emit launch. The namespaced `app-open-activity` key was persisted. This changes spacing across restarts and keeps an activity timestamp outside the documented session-disabled storage behaviour.

This is not a behavioural-consent bypass: collection is still consent-gated. It is also distinct from persisting pending app-open reports, which the contract requires for retry.

**Correction:** separate the in-memory spacing clock from the persistent pending-report queue, selecting the spacing behaviour from `trackSessions`. Check consent withdrawal and user transitions in both modes.

## Contract coverage

| Area | Current assessment |
| --- | --- |
| Public options and methods | All shared mobile methods are present, with Swift naming, defaults and async style. `trackScreenView` is explicit; no public API expansion is needed for this review. |
| Auth and tenancy | Client-key/API-host namespaces, captured user subjects, memory-only JWTs and same-subject refresh are sound foundations. Cleanup refresh and diagnostic state need the fixes above. |
| Event ownership | Owned records stay bound across retries; unbound events are adopted at sign-in; logout removes the outgoing user's unsent events. Queue sharing prevents independent in-process clients from adopting the same unbound records separately. Reviewed existing tests; did not run them. |
| Serialization/redaction | Capture copies JSON values; unsupported values fail closed; automatic events pass through the synchronous native hook; retry reuses the stored snapshot. Re-entry is guarded and hooks run outside the tracker lock. |
| Queue/delivery | Count/byte budgets, split handling, per-key acknowledgements, transient codes, jitter and Retry-After exist. IOS-01 remains a data-loss hole in malformed-result handling. |
| Sessions/lifecycle | Owner-bound visits, foreground keepalive and optional lifecycle events are present. Initial synchronous launch work needs IOS-05; app-open spacing needs IOS-06. |
| Consent | Latest dual-store refusal rules, grant/refusal precedence and recovery from unreadable storage are implemented. Operational receipts/taps are separate from behavioural consent. Marketing consent throws when not recorded. |
| Push registration | APNs/FCM selection, runtime Firebase lookup, daily refresh, notification permission and device preference exist. API support for timestamp-guarded detach must be verified on the deployed backend before release. |
| Notifications | Marker filtering, foreground delegation, tap deduplication, manual forwarding, extension delivery/images and completion-on-expiry are present. External link routing needs IOS-04. |
| Wrappers | SPI covers SDK header override, token requests, held launch taps, callback timeouts and the concurrent `wrapperDetached()` addition. Native builds include the refreshed implementation. This is not a full React Native/Flutter bridge or runtime audit. |
| Packaging/privacy | Two separate SwiftPM products, two podspecs, MIT license and target-specific privacy manifests exist. No third-party package dependencies. Publication, app archives and App Store privacy aggregation were not verified. |

The spec's “built, awaiting review” change log and previous report's fixed statuses are implementation claims, not independent verification. No coverage percentage is assigned: not every contract case was executed.

## Comparison with Customer.io and Iterable

Competitor documentation was consulted on 17 November 2026. These are integration benchmarks, not specifications Kirora must copy. Kirora's shared contract controls required behaviour; feature differences below do not automatically justify adding public methods or dependencies.

| Dimension | Kirora | Customer.io | Iterable | Recommendation |
| --- | --- | --- | --- | --- |
| Installation | Separate main and extension products; SPM and source podspecs; iOS 13 minimum | Current quickstart documents SPM/CocoaPods and iOS 15+ | Official package/docs declare iOS 10+ and separate SDK/extension products | Keep target selection explicit; verify an actual published release and device build rather than treating lower deployment targets as stronger validation. |
| Identity | Mandatory server-signed user JWT; pre-identify events wait locally | User identification and clearing identity are documented separately from push setup | Email/user-ID identification plus configurable JWT authentication | Keep Kirora's server-derived identity boundary. Distinguish selecting a token locally from server acceptance. |
| Push integration | Automatic delegate proxy by default; Info.plist opt-out and manual forwarding | Current quickstart uses `CioAppDelegateWrapper`; separate APNs/FCM modules | Documents automatic registration configuration plus app callback integration | Document setup order and coexistence. Do not present swizzling as automatically equivalent to either vendor's current approach. |
| Auth/retries | One refresh per refused call; offline event retries and bounded logout | SDK-specific identity and messaging lifecycle | Auth delegate, failure callbacks and configurable retry policy; offline JWT retry has its own documented configuration | Keep lifecycle/identity guarantees explicit; fix cleanup semantics instead of importing an unrelated retry policy. |
| Rich push | Independent helper reports delivery and downloads images; actions need category integration | Notification extension with optional App Group recovery for lost metrics | Extension handles rich attachments/actions; guides explain category-rich setup | Keep Kirora's best-effort receipt model honest. App Group recovery would be a separate contract/product decision. |
| Messaging scope | Events, sessions and push; no inbox/in-app messaging renderer | Documents in-app messaging alongside push | Documents in-app, Mobile Inbox and embedded messaging | Treat these as product-scope differences, not missing features required by Kirora's current spec. |
| Developer support | Broad fake-transport/conformance coverage, but no sample iOS app or CI workflow found in this snapshot | Dedicated integration/configuration/troubleshooting docs and modular samples | Sample projects, setup verification and upgrade guidance | Add a small retained-client sample and native build/release checks in a later authorized implementation task. |

Sources for installation and current integration patterns: [Customer.io quickstart](https://docs.customer.io/integrations/sdk/ios/quick-start-guide/), [Customer.io push setup](https://docs.customer.io/integrations/sdk/ios/push/push-setup/), [Iterable iOS setup](https://support.iterable.com/hc/en-us/articles/360035018152-Iterable-s-iOS-SDK), [Iterable identification](https://support.iterable.com/hc/en-us/articles/360035402531-Identifying-the-User), [Iterable package](https://github.com/Iterable/iterable-swift-sdk/blob/master/Package.swift).

Sources for richer messaging and release practices: [Customer.io rich push](https://docs.customer.io/integrations/sdk/ios/push/rich-push/), [Customer.io App Group introduction](https://docs.customer.io/integrations/sdk/ios/whats-new/4.4.0-upgrade/), [Iterable advanced push](https://support.iterable.com/hc/en-us/articles/360035451931-Advanced-iOS-Push-Notifications), [Iterable SDK repository and sample projects](https://github.com/Iterable/iterable-swift-sdk). The iOS setup article also documents Iterable's JWT delegate and offline-auth retry configuration; this review does not claim every configuration is enabled by default.

### Product gaps and integration limits

- **Action buttons:** reading `buttons` and handling a synthetic button tap does not make actions appear on iOS. Kirora registers no `UNNotificationCategory` and its standard extension does not set `categoryIdentifier`; the current APNs sender supplies no corresponding category. This is an incomplete turnkey integration, already partially acknowledged in source/README, rather than proof that tap parsing is broken. The rewritten README now explains the category-assignment requirement. See [Apple's actionable-notification guide](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types). Decide separately whether the SDK/extension should supply automatic category support.
- **Operational receipts:** extension/tap reports retry once and are not durably recovered. Customer.io documents App Group-based recovery. Kirora's simpler dependency-free helper follows its current spec; do not claim comparable recovery or guaranteed metrics. Adding shared storage requires an explicit contract decision.
- **Local data:** event/state JSON uses app-container storage and backup exclusion, not SDK-level encryption. Iterable documents encryption of some stored data. This is a documented design difference, not proof of a sandbox escape. Keep sensitive values out of events and disclose app-specific collection accurately.
- **Firebase compatibility:** runtime Objective-C lookup avoids a package dependency, but the string-based token-refresh observation and selectors should be exercised against the Firebase versions actually supported. There was no configured Firebase app/device here, so working token refresh is not claimed.
- **Delegate coexistence:** Catalyst compilation verifies types, not swizzle chaining with Firebase, another notification provider, SwiftUI launch delivery or multi-scene routing. These require real app checks.

## Verification performed and limits

Builds used an isolated source copy under `/private/tmp/kirora-ios-review-20261117`, with caches and output outside the repository. SwiftPM's nested sandbox required tool approval; the first temporary-copy attempt also needed the Tests directory present for correct target discovery. Those setup failures were not SDK defects. Final builds passed:

```sh
swift build --scratch-path <temporary-build> -Xswiftc -strict-concurrency=complete

swift build --triple arm64-apple-ios15.0-macabi --sdk "$SDK" \
  -Xswiftc -Fsystem \
  -Xswiftc "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -Xswiftc -strict-concurrency=complete --scratch-path <temporary-catalyst-build>
```

Environment: Apple Swift 6.2, arm64 macOS, Command Line Tools selected. The final incremental refresh included concurrent wrapper teardown changes. These checks do not establish compilation with every compiler/deployment version declared by the package.

A standalone temporary executable compiled the actual core SDK sources with copied fake-transport/lifecycle support. It did not invoke `swift test` or add/change repository tests. Its observed outputs were:

```text
malformed_ack_before=1
malformed_ack_after=0
restart_identified=false, restart_pushToken=abcd01
failed_transfer_pushToken=abcd01, push_status=disabled
detach_fetchUserToken_calls=1, detach_requests=2
synchronous_launch_init_ms=373
sessions_off_persisted_open_spacing=true
```

The rewritten README's retained-client, SwiftUI, manual-delegate and usage examples also passed Catalyst typechecking in Swift 6 language mode with strict concurrency, using explicit stubs for the host app's token fetch and view. This is API/example validation, not a running app or real authentication check.

The lifecycle delay was deliberately injected. The transport probes used fake credentials, fake HTTP responses and temporary files; no production API, APNs, Firebase or user account was contacted. A large unsigned-number serialization probe produced a finite double; the hypothesised signed-overflow issue was not observed and is not reported as a defect.

**Not performed:** test-suite execution, full Xcode iOS archive/device/simulator run, real push delivery/taps, background termination by iOS, CocoaPods lint/install, remote tag/registry publication verification, App Store privacy validation or external-network security testing. No fresh test count is claimed. Existing tests were inspected for intent and gaps only.

## README rewrite

The rewritten README provides installation by target, a retained launch client with UIKit/SwiftUI wiring, server-derived token setup, consent-first event capture, delivery/storage semantics, manual push forwarding, extension setup and a concise API reference. It distinguishes permission from registration and marketing consent, documents mixed-provider/category requirements, removes the absolute no-startup-I/O claim and includes the unresolved limitations above. It avoids claiming a source version or podspec is already published.

## Recommended next implementation pass

1. Fix IOS-01 and prove malformed acknowledgements retain events.
2. Fix IOS-02 and IOS-03 together around registration ownership and outgoing credentials.
3. Fix IOS-04 and IOS-05 with an actual UIKit sample/lifecycle ordering; then reconcile IOS-06.
4. Run the repository's authorised conformance checks in that implementation task and exercise the sample on iOS with APNs/FCM, mixed providers, account switches and offline logout.
5. Verify backend timestamp-guarded detachment and distribution artifacts before release. Reconcile README caveats and changelog claims when fixes land.

## Historical reviews

The earlier report is retained below without treating its old test counts or resolved verdicts as current validation.

<details>
<summary>14–16 November 2026 review history</summary>

# Kirora iOS implementation review

Reviewed 14 November 2026. Scope: the working-tree implementation, public API, persistence,
identity, event delivery, lifecycle, push integration, notification extension, tests and
README. This is a review and documentation change. Existing concurrent logout changes were
preserved and included in validation.

**Status, 14 November 2026: all six findings are fixed**, each with regression tests; see
"Resolution" under each finding. R6's SDK side is done; its sender side, the `kirora`
marker on every iOS push, is with the backend.

The governing contract is `docs/sdk-interface.md` in the sibling omnichannel repository
(`../../omnichannel/docs/sdk-interface.md` from this repository's root). The web SDK's
identity and consent implementation was also available locally. Customer.io is a reference
for integration and testing practices, not a reason to change Kirora's public contract or
add dependencies.

## Assessment

The small, dependency-free design is a good foundation. In particular, queued events carry
an owner, requests capture a `SignedInUser`, and token refresh rejects a replacement for a
different subject. Delivery checks the active user and consent between batches. The queue
is bounded, acknowledges individual results, and splits invalid batches. The notification
extension is independent of the main SDK and protects completion with a lock.

Address the P1 findings before relying on the documented host-app safety, consent and
logout guarantees. Passing the current tests does not cover these edge cases.

| ID | Priority | Finding | Evidence | Status |
| --- | --- | --- | --- | --- |
| R1 | P1 | Oversized `Retry-After` can terminate the host app | Isolated process crash | Fixed |
| R2 | P1 | App-open activity is stored before consent, even with push off | Isolated behavioral probe | Fixed |
| R3 | P1 | Logout's five-second deadline excludes pending identification | Isolated behavioral probe | Fixed |
| R4 | P2 | Startup and some synchronous APIs perform disk I/O | Source inspection | Fixed |
| R5 | P2 | Destroying during detachment can allow new retries afterward | Isolated behavioral probe | Fixed |
| R6 | P2 | Generic payload keys can capture another provider's push | Parser probe and source inspection | Fixed in the SDK; marker with the backend |

P1 means a high-impact safety or contract failure; P2 means a correctness or integration
issue that should be fixed in the next implementation pass.

## Findings

### R1 P1 Oversized Retry-After can terminate the host app

**Location:** [ClientAPI.swift, `retryAfterMs`](../Sources/Kirora/Internal/ClientAPI.swift#L152),
especially the unchecked `Int(delayMs)` conversion at line 165. Retry scheduling also
converts seconds to `UInt64` nanoseconds in delivery, app-open and detach tasks.

**Trigger:** a failed response contains `Retry-After: 99999999999999999999`. `Double`
accepts the header, but converting milliseconds to `Int` traps. The isolated probe
`retryAfterMs("99999999999999999999")` exited with signal 5 and:
`Double value cannot be converted to Int because the result would be greater than Int.max`.
An infinite value can reach the same unsafe conversion. This escapes the error handling
and violates the rule that Kirora failures must never break the host app.

**Recommended fix:** validate finite, positive values and representable bounds before every
numeric conversion. Define a safe policy for impractically distant retry deadlines; use
bounded sleep intervals while preserving the server's deadline rather than overflowing or
retrying early. Cover huge numeric values, infinity, negative values, invalid dates and a
valid delay that fits milliseconds but overflows nanoseconds.

**Resolution:** `retryAfterMs` only accepts a finite, positive delay and cuts one past a
week to a week (`maxWaitSeconds`). Every wait goes through `sleep(seconds:)`, which treats
negative and NaN as no wait and cuts anything longer, infinity included, so no conversion
can trap. A retry after a cut wait that is still too early is refused and backs off again.
Tests: `readsRetryAfter` (huge, `inf`, `nan`, negative, invalid date) and
`sleepingNeverTrapsOnAnyValue`.

### R2 P1 App-open activity is stored before consent

**Locations:** [AppOpens.swift, `appCameToForeground` and `touchVisit`](../Sources/Kirora/Push/AppOpens.swift#L59),
and [Kirora.swift, lifecycle handling](../Sources/Kirora/Kirora.swift).

**Trigger:** create a fresh client with `requireTrackingConsent: true` and push disabled,
then deliver `.launched`. `AppOpens.touchVisit()` writes `app-open-activity` into the store.
Background and keep-alive callbacks update it too. It has neither a tracking consent gate
nor a push-enabled gate. `setTrackingConsent(false)` clears events and the session but
does not clear this timestamp.

**Impact:** the promise to track and store nothing before consent is false even for an
events-only integration. The existing `tracksAndStoresNothingBeforeConsent` test checks
events, session and device id, but misses this key. Push reporting is explicitly separate
from event consent in the contract; that does not justify app-open storage when push is off.

**Recommended fix:** avoid creating/updating app-open state when push reporting is disabled.
Specify in the shared interface which push-reporting state may exist before event consent,
then implement and document that boundary consistently. Check all persisted keys on a fresh
store, after launch/background/keep-alive, and after consent withdrawal. Preserve the user's
consent answer itself.

**Resolution:** app-open state is only read or written when push is on
(`AppOpens` checks `registrar.enabled`). With push off and consent required, the store is
empty before consent, and holds only the answer after a withdrawal. The interface already
places push reporting outside event consent; nothing else is stored before consent with
push off. Test: `storesNothingAtAllBeforeConsentWithPushOff`, which checks every key after
launch, keep-alive, background and foreground.

### R3 P1 Logout's deadline excludes pending identification

**Location:** [Kirora.swift, `logout`](../Sources/Kirora/Kirora.swift#L134).

`await identity.settled()` runs before `withTimeout(seconds: logoutWait)`. An in-progress
`fetchUserToken` can therefore consume its full 30-second timeout before the five-second
send/detach window starts. Identification can also include push calls and token waits.
The shared interface promises that logout waits five seconds at most in total.

**Reproduction:** in a temporary copy, set `logoutWait` to 20 ms, start identification with
a 250 ms token callback, then call logout once that callback starts. Logout takes more than
150 ms. The existing logout deadline test covers slow delivery, not pending identification.

**Recommended fix:** apply one deadline to the entire logout operation, including pending
identification. Ensure an identification result arriving after logout cannot restore the
user. Keep eventual detachment serialized behind any registration that must finish, using
the captured old user's credentials. Test pending token fetch, slow push registration,
concurrent identification and repeated logout. The README now describes the present limit
instead of asserting a five-second total bound.

**Resolution:** one deadline covers all of `logout()`. Waiting for a pending sign-in is
bounded by it; a sign-in still waiting for its token when time runs out is abandoned
(`Identity.abandonPendingSignIn`), so its token can't sign the user back in, while whoever
is signed in is signed out as usual. Sending and detaching get what is left; a detachment
still under way carries on in the background, behind any registration through the
registrar's serial queue, with the old user's captured credentials. Test:
`logoutsDeadlineIncludesASignInStillWaitingForItsToken`.

### R4 P2 Startup and synchronous cleanup can block on disk

**Locations:** [Storage.swift, `StorageLocation.directory`, `PersistentFile.read`, and
`FileKeyValueStore.init`](../Sources/Kirora/Internal/Storage.swift#L48);
[EventQueue.swift, `load`](../Sources/Kirora/Internal/EventQueue.swift#L129);
[Kirora.swift, initialization and `destroy`](../Sources/Kirora/Kirora.swift).

Client construction creates/configures the storage directory and synchronously reads and
decodes `state.json`. If consent was previously refused, constructor cleanup can also load
the persisted event queue. Synchronous queue mutation can wait on the same lock while
delivery loads it. `destroy()` explicitly waits for queued file writes. Constructing the
client on the main thread, as required for timely push installation, therefore exposes
launch to filesystem latency. The claim that storage reads always come from memory is
incorrect during initialization.

**Recommended fix:** install the necessary UIKit callbacks immediately, but load persistent
state on a background executor and buffer operations in order until ready. Preserve consent
and event ownership while loading. Measure startup with large and unreadable state files;
exercise slow reads and pending writes. The README now distinguishes no network wait from
no synchronous I/O. No launch-time measurement was made in this review.

**Resolution:** the client never reads or creates files on the calling thread at start.
`StorageLocation` only works out the path; the directory is made, and left out of backups,
by the first write. The state file and event queue are read on each file's own serial
queue in the background, shared by every client in the process, so a client started after
another reads everything it wrote and `destroy()` no longer waits for writes. Events
tracked before the read are kept after those read and written with them at once. The
start-up consent cleanup runs off the calling thread, under the tracker's lock, so an event
tracked just after consent is granted is never cleared with the rest. A value needed in the
first moments (such as tracking consent) waits for that read, a file of a few hundred
bytes; the README says so. Tests: `aClientStartedStraightAfterAnotherSeesItsEvents`,
`theStateFileIsReadAndWrittenOffTheCallersThread`. No launch-time measurement was made.

### R5 P2 Destroying during detachment can allow new retries afterward

**Locations:** [PushRegistrar.swift, `detach` and `stopRetrying`](../Sources/Kirora/Push/PushRegistrar.swift#L210),
and [Kirora.swift, `destroy`](../Sources/Kirora/Kirora.swift#L218).

`destroy()` cancels the retry task currently stored in `detachRetry`. If an initial DELETE
is awaiting its response, there is no retry task to cancel yet. A subsequent retryable
failure makes `detach()` create and store a new task after destruction. `attemptDetach`
allows a captured user when `identity.user` is nil, so ending identity does not stop it.

**Reproduction:** register a user, make DELETE fail after 150 ms, start logout, destroy the
client once DELETE is observed, then let it fail. A second DELETE is sent after destruction.
This was confirmed in the isolated probes. The existing destroy test destroys only after
logout's first failure has already installed its retry task.

**Recommended fix:** give the registrar an irreversible stopped state or generation checked
before starting operations and installing retries. Cancellation should close the race
between an awaited response and scheduling the next task. Add regression tests for destroy
during initial DELETE, retry DELETE and a preceding event flush. Already-sent HTTP requests
cannot be recalled; the requirement is to prevent new work after destruction.

**Resolution:** the registrar has a permanent stopped state, set by `destroy()`, and a
generation counted by each stop. A detachment captures the generation before its first
attempt and only schedules retries if it is unchanged and not stopped; retries check it
again before each attempt, and no registration or detachment starts once stopped. Test:
`aDestroyDuringTheFirstDetachStopsRetriesToo`, alongside the existing destroy and sign-in
tests.

### R6 P2 Generic payload keys can capture another provider's push

**Locations:** [PushTapHandler.swift, `KiroraPushPayload.init`](../Sources/Kirora/Push/PushTapHandler.swift#L32),
[Kirora+Push.swift, manual callbacks](../Sources/Kirora/Push/Kirora+Push.swift), and
[KiroraNotificationService.swift, `didReceive`](../Sources/KiroraNotificationService/KiroraNotificationService.swift#L43).

An unrelated payload containing only `actionUrl: "https://other.example/promo"` is accepted
as Kirora's. The manual callback returns true, so an app following the README skips its own
handling. Automatic integration can open that URL as well as the host delegate handling
it. The extension similarly claims any payload with a parseable `imageUrl` or `trackingUrl`
and may download an image or POST a report to the supplied address.

**Recommended fix:** define an unambiguous Kirora marker or namespaced payload in the shared
wire contract and sender first. Retain explicit support for dashboard test sends without
tracking URLs. Validate URL schemes and test mixed providers, malformed payloads and
duplicate manual/automatic forwarding. This needs a coordinated backend/SDK change;
inventing a new payload requirement only in this repository would break existing pushes.

**Resolution:** a push is Kirora's only with the top-level `kirora` marker or a
`trackingUrl` at Kirora's tracking path (`/t/p/`), which every tracked push from current
servers has. A bare `actionUrl`, `imageUrl` or other `trackingUrl` never counts, in the app
or the extension. Tracking URLs must be HTTP(S), images HTTPS, and links with
`javascript:`, `data:`, `file:` or `vbscript:` schemes are never opened. The backend has
been asked to send `kirora: "true"` on every iOS push, as Android's data messages carry,
and to add it to the interface; until then, a dashboard test send without `trackingUrl`
isn't recognised on iOS (it shows normally, but its link isn't opened). Test:
`onlyAMarkedPushOrKirorasTrackingPathIsKiroras`.

## Customer.io reference

Inspected GitHub repository `customerio/customerio-ios` at commit
[`12b919acc2dd84ee462dbd4d1bd593a8101e7044`](https://github.com/customerio/customerio-ios/tree/12b919acc2dd84ee462dbd4d1bd593a8101e7044),
dated 11 November 2026. The comparison uses source from a shallow checkout, not just the
repository's README. No Customer.io code or dependency was added to Kirora.

Useful practices to carry over:

- **Target selection:** Customer.io's [README](https://github.com/customerio/customerio-ios/blob/12b919acc2dd84ee462dbd4d1bd593a8101e7044/README.md)
  separates SDK products and their purposes. Kirora's README now names the app and extension
  targets explicitly, while retaining Kirora's simpler two-product design.
- **Runtime integration testing:** [app-delegate tests](https://github.com/customerio/customerio-ios/blob/12b919acc2dd84ee462dbd4d1bd593a8101e7044/Tests/MessagingPush/Integration/CioProviderAgnosticAppDelegateTests.swift)
  exercise the UIKit integration. Kirora's protocol fakes cover business logic well, but
  do not execute its swizzler, notification delegate proxy or SwiftUI forwarding. Add
  tests on an iOS test host for inherited/forwarded delegates, delegate replacement,
  Firebase coexistence, cold-start taps and exactly-once completion.
- **Preserving callbacks:** [AppDelegateSwizzler](https://github.com/customerio/customerio-ios/blob/12b919acc2dd84ee462dbd4d1bd593a8101e7044/Sources/MessagingPush/Integration/AppDelegateSwizzler.swift)
  handles existing implementations, inheritance and forwarding. Kirora uses a similar
  approach; verify these cases with tests rather than treating typechecking as evidence
  that runtime replacement works.
- **Payload ownership:** Customer.io's [PushNotification](https://github.com/customerio/customerio-ios/blob/12b919acc2dd84ee462dbd4d1bd593a8101e7044/Sources/MessagingPush/Type/PushNotification.swift)
  recognizes its delivery through provider-specific keys. This is a useful reference for
  resolving R6 without confusing another provider's generic fields.
- **Deep-link routing:** [DeepLinkUtil](https://github.com/customerio/customerio-ios/blob/12b919acc2dd84ee462dbd4d1bd593a8101e7044/Sources/Common/Util/DeepLinkUtil.swift)
  tries an explicit application callback before host/system routing. Kirora already has
  `handleDeepLink`; document and test that path, especially in scene-based apps.
- **Concurrent rich pushes:** [RichPushRequestHandler](https://github.com/customerio/customerio-ios/blob/12b919acc2dd84ee462dbd4d1bd593a8101e7044/Sources/MessagingPush/RichPush/RichPushRequestHandler.swift)
  scopes requests and cancellation. Add extension tests for concurrent notifications,
  expiration during image/report requests and exactly-once content delivery.

Customer.io's feature set and platform requirements do not replace Kirora's iOS 13 floor,
zero-dependency rule or signed-user token model.

## Documentation changes

The README now provides a product/target table, retained UIKit and SwiftUI clients, an
explicit app-owned token-fetch contract, and a first identify/track/flush example. It also
clarifies local identification versus server validation, consent boundaries, logout timing,
asynchronous persistence, best-effort reports and extension setup. The storage table now
separates the retained APNs token from push registration records and distinguishes active
identity from credentials retained by detachment work. Privacy manifest descriptions now
match the two different targets.

These corrections document current behavior; they do not relax the shared contract. Once
the findings are fixed, update the corresponding caveats alongside regression tests.

## Validation and remaining coverage

After the fixes: `./scripts/test.sh` passes **82 tests**, three runs in a row; the strict
concurrency macOS build and the strict Mac Catalyst build are clean. The original checks:

- `./scripts/test.sh --scratch-path /private/tmp/kirora-review-build`: **75 tests passed**.
- `swift build -Xswiftc -strict-concurrency=complete` with an isolated scratch path:
  **passed**, no concurrency diagnostics.
- Required arm64 Mac Catalyst build with strict concurrency and the iOSSupport framework
  search path: **passed**. This typechecks the UIKit branch.
- Four temporary behavioral probes: **passed**, confirming R2, R3, R5 and the parser portion
  of R6. These assertions demonstrate undesirable current behavior, not fixes. They ran in
  a copy under `/private/tmp` and were not added to the repository's test suite.
- R1's separate crash probe: **terminated with signal 5 as predicted**. It ran outside the
  normal suite in the temporary copy.
- Native iOS `xcodebuild`: **not available**. The selected developer directory contains
  Command Line Tools, not full Xcode. No device, simulator, APNs/Firebase service, dashboard,
  real notification extension invocation or backend end-to-end test was performed.

Initial sandboxed Swift builds could not access compiler caches; the successful checks
were rerun with approved cache access. The test link emitted an environment warning that
the local Testing framework targets a newer macOS than the package's test binary.

After the fixes, add the missing regressions above and run a real-device smoke test on the
minimum supported OS. Include offline logout/relaunch, account switching while delivery is
in flight, privacy manifest inspection in an archived app, consent grant/withdrawal and
extension expiration. Successful Catalyst compilation does not establish iOS 13 runtime
behavior or push-provider interoperability.

## Second review: the 14 and 16 November interface

Reviewed and fixed 16 November 2026, against `sdk-interface.md` after its 14 and 16
November changes. Each behaviour finding was first confirmed with a temporary failing test,
then fixed with a regression test in the suite, mostly in
`Tests/KiroraTests/ConformanceTests.swift`. **Status: all fixed.**

| ID | Finding | Fix |
| --- | --- | --- |
| S1 | `getPushStatus()` and `setPushEnabled(_:)` missing | Added, following the web SDK: a per-workspace device choice, cleanup on off, no prompt on on |
| S2 | `beforeSend` missing | Added: once per event before storage, re-entry refused, throw/nil/non-JSON drops, retry keeps the redacted copy |
| S3 | App opens collected and sent without tracking consent | Gated on consent; withdrawal drops waiting opens, their spacing and any retry or send under way. Supersedes R2's reading of the old interface |
| S4 | `RATE_LIMITED`, `INTERNAL_ERROR`, `SERVICE_UNAVAILABLE` per-event results dropped; repeated results acknowledged | Retried; a repeated, unreadable or unknown result acknowledges nothing |
| S5 | Another user's sign-in, or failed registration, cancelled the signed-out user's detachment | Only a successful registration (or denial) of the same installation ends it, as the web SDK's `finishCleanups` |
| S6 | Events from before sign-in stayed unowned until acknowledged, so they could go as a later user | Adopted at sign-in; released if Kirora refuses the token before ever accepting it |
| S7 | Visits not tied to a user | Stored with their owner; logout ends the visit; another user begins their own |
| S8 | Non-JSON values changed (NaN to null) or left out instead of dropping the event; `nil` sent as null | Strict snapshot: the event is dropped and the kind of problem logged; `nil` members left out; self-containing arrays caught |
| S9 | Device id, visit, consent and app state shared across workspaces | Kept per workspace and deployment (`WorkspaceStore`); 0.1.0 values moved over, a consent answer copied |
| S10 | An unreadable consent file fell back to the default grant | Tracking waits for a fresh answer, with a diagnostic |
| S11 | No 1,000,000-byte queue budget | Added; an event larger than the budget is dropped itself |
| S12 | Events tracked during `logout()` were bound to the outgoing user and dropped | They wait for the next user |
| S13 | Tapped notification buttons didn't open their link | `buttons` read; the action identifier names the button by position or title |
| S14 | Empty event names refused on the device | Left to the server |
| S15 | Clients in one process each wrote whole files, overwriting each other (two workspaces' `state.json` included) and able to adopt the same events | One queue and one store per file per process (`SharedPerFile`) |
| S16 | Requests in flight not cancelled on consent withdrawal or at the logout deadline | Cancelled (`URLSessionTransport` honours task cancellation); a detachment cancelled at the deadline is retried |
| S17 | Uncommitted change re-registered on language, time zone or app version changes, against "repeated only when the user, the push token or the day changes" | Reverted; the details go with each registration and daily refresh. Changing this needs the shared interface first |

Afterwards: when the queue can't be saved, it logs once that events are kept in memory
only and won't survive a restart (the interface's wording for unavailable storage).

Not applicable: an asynchronous `beforeSend` answer (a Swift closure can't give one).

Validation: `./scripts/test.sh` passes 118 tests; the strict-concurrency macOS build and the
strict Mac Catalyst build are clean. Mutation checks (reverting a fix) made the matching new
tests fail for S5, S10, S12, S15 and S16. Native `xcodebuild` remains unavailable here, and
none of this has run on a device.

## Code review of the second pass, and the `lastSeenAt` detach

16 November 2026. A code review of the uncommitted second pass found nine bugs and one
inefficiency; the interface also changed the detachment the same day (`DELETE
/devices/{id}?lastSeenAt=`, not yet deployed). Both were done together, as they touch the
same code. **Status: all fixed**, each with a regression test.

| ID | Finding | Fix |
| --- | --- | --- |
| C1 | `detach()` read the registration before waiting its turn, so one still under way at sign-out stayed registered | Reads it in its turn, behind registrations; a registration for a user signing out doesn't start |
| C2 | A detachment refused for good, or given up, dropped the record and device id while Kirora still had the device | The record is kept, marked as detaching, until Kirora confirms (204 or 409) |
| C3 | An unreadable `state.json` loaded as empty, and the next save erased a refusal | A `tracking-consent-unknown` marker is saved; a file that can't be opened is never written over |
| C4 | A per-client in-memory answer overrode the shared one | The answer lives only in the shared store |
| C5 | Events tracked during `logout()` joined the outgoing user's visit | Logout ends that visit as it starts; one begun meanwhile becomes the next user's |
| C6 | A refusal's delayed cancel could cancel a later grant's send | The cancel checks consent in turn |
| C7 | Logout's deadline cancel dropped a new sign-in's send | Cancels only the outgoing user's send; one asked for meanwhile still goes |
| C8 | `beforeSend` ran under the tracker's lock: a hook waiting on another tracking thread froze the app | Runs outside the lock |
| C9 | A missing push token logged twice and marked the registration failed | Logged once |
| C10 | Adoption re-encoded the whole queue | Sizes change by the owner's bytes |

The `lastSeenAt` contract: every detachment names the `lastSeenAt` of the device's last
successful `PUT /devices` (none for a device without one, which detaches unconditionally);
204 and 409 end it, another 4xx except 429 ends it as refused, and a network error, 429 or
5xx is retried as before. The device-side cancellation of a detachment on another
registration (`finishCleanups`) is gone, as the interface asks: the server's answer decides.

Validation: `./scripts/test.sh` passes 130 tests; strict-concurrency macOS and Mac Catalyst
builds are clean. Reverting C3, C5 and C6 made their tests fail. Not to ship until the
server change is deployed.

</details>
