# Kirora iOS SDK

## Unreleased

- Clarify installation targets, client retention, token fetching and first-event setup.
- Document consent boundaries, storage retention and best-effort push reporting.
- Fix issues found in review:
  - An oversized `Retry-After` can no longer crash the app.
  - Nothing is stored before tracking consent with push off.
  - `logout()` takes 5 seconds at most in all, a pending `identify()` included.
  - Starting the client no longer reads the disk on the calling thread.
  - `destroy()` during a detachment stops its retries.
  - Only pushes marked as Kirora's, or with Kirora's tracking URL, are handled.

## 0.1.0

First release: event tracking, sessions, screen views, app lifecycle events, tracking
consent and push (registration, taps, app opens, and deliveries and images from a
Notification Service Extension).
