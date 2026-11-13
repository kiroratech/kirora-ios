import Foundation

/// The delivery timings every Kirora SDK shares. Tests shorten them.
struct DeliveryTiming: Sendable {
    /// Send at once when this many events wait…
    var flushAtEvents = 20
    /// …otherwise this long after the first one waits. Also the first retry delay.
    var flushInterval: Double = 30
    /// Retries double up to this.
    var maxRetryDelay: Double = 5 * 60
}

/// The API accepts at most 100 events per batch (`MAX_EVENT_BATCH`).
let eventBatchSize = 100
/// Stays under the server's body limit. A 413 gets split anyway.
private let maxBatchBytes = 200_000
/// `{"sentAt":"…","events":[]}` around the events.
private let envelopeBytes = 64
/// Answers that blame something in the batch: halving it finds the event to drop.
private let splitStatuses: Set<Int> = [400, 413, 422]

/// Sends queued events in batches, retrying with backoff. Each user's events are only ever
/// sent with that user's token, and nothing is sent without tracking consent.
actor EventDelivery {
    private let api: ClientAPI
    private let identity: Identity
    private let queue: EventQueue
    private let consentAllowed: @Sendable () -> Bool
    private let log: Log
    private let timing: DeliveryTiming
    /// The device's clock, for `sentAt`. Waiting and backoff go by real time.
    private let now: @Sendable () -> Date

    private var timer: Task<Void, Never>?
    private var timerAt = Date.distantFuture
    private var flushing: Task<Void, Never>?
    /// A flush was asked for while one was sending: it goes once more after.
    private var rerun = false
    /// A flush() asked to skip the SDK's own backoff (never the server's `Retry-After`): the
    /// next send does, whoever started it.
    private var backoffWaived = false
    private var backoff: Backoff
    private var destroyed = false

    init(
        api: ClientAPI,
        identity: Identity,
        queue: EventQueue,
        consentAllowed: @escaping @Sendable () -> Bool,
        log: Log,
        timing: DeliveryTiming,
        now: @escaping @Sendable () -> Date
    ) {
        self.api = api
        self.identity = identity
        self.queue = queue
        self.consentAllowed = consentAllowed
        self.log = log
        self.timing = timing
        self.now = now
        backoff = Backoff(timing)
    }

    /// Stops for good: no more timers or sends. Queued events stay stored.
    func destroy() {
        destroyed = true
        stopTimer()
    }

    /// After an event is queued: send at once if enough wait, otherwise soon.
    func onEventQueued(waiting: Int) {
        guard identity.user != nil, !destroyed else { return }
        if waiting >= timing.flushAtEvents {
            Task { await self.flushWhenDue() }
        } else {
            schedule(Date().addingTimeInterval(timing.flushInterval))
        }
    }

    /// Sends queued events now, if a user is signed in, without waiting out our own backoff
    /// (never the server's `Retry-After`). Returns once sending stops, which doesn't mean
    /// every event was accepted: some may wait for a retry.
    func flush() async {
        backoffWaived = true
        await flushWhenDue()
    }

    /// Sends once any backoff has passed. One send at a time: if one is running, goes again
    /// after it, as it may have read the queue before the latest events were added.
    private func flushWhenDue() async {
        if let running = flushing {
            rerun = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                self.rerun = false
                await self.send()
            } while self.rerun
            self.flushing = nil
        }
        flushing = task
        await task.value
    }

    /// Sends batch after batch for the user signed in now, until the queue is empty.
    private func send() async {
        stopTimer()
        let skipBackoff = backoffWaived
        backoffWaived = false
        guard !destroyed else { return }
        if Date() < backoff.notBefore(waivingOwnDelay: skipBackoff) {
            schedule(backoff.notBefore())
            return
        }
        // Bound to the user signed in now. If the app changes user, the next identify()
        // flushes for them.
        guard let user = identity.user else { return }
        var maxEvents = eventBatchSize
        while mayStillSend(as: user) {
            let batch = fitBatch(queue.oldest(maxEvents, owner: user.subject))
            if batch.isEmpty { return }
            let outcome = await sendBatch(batch, as: user)
            switch outcome {
            case .split:
                maxEvents = (batch.count + 1) / 2
                continue
            case .stop:
                return
            case .settled(let keys):
                queue.remove(keys)
                // Past the event a split isolated, the rest go in full batches again.
                maxEvents = eventBatchSize
                if keys.count < batch.count {
                    log.error("Kirora's answer didn't cover every event; retrying the rest")
                    schedule(backoff.failed(nil))
                    return
                }
                backoff.succeeded()
            }
        }
    }

    private func mayStillSend(as user: SignedInUser) -> Bool {
        identity.user === user && !destroyed && consentAllowed()
    }

    private enum Outcome {
        /// The events sent, or refused for good.
        case settled(Set<String>)
        case split
        case stop
    }

    private func sendBatch(_ batch: [QueuedEvent], as user: SignedInUser) async -> Outcome {
        let keys = Set(batch.map(\.idempotencyKey))
        do {
            let sent = try await api.request(
                "POST", "/events/batch",
                // `sentAt` lets the server correct for the device's clock.
                body: BatchBody(sentAt: isoTimestamp(now()), events: batch),
                as: user
            )
            let settled = acknowledgedKeys(sent, batchKeys: keys)
            log.debug("Sent \(settled.count) events")
            return .settled(settled)
        } catch {
            return classifyFailure(error, batchKeys: keys)
        }
    }

    /// What a failed batch means: try later, stop, split it, or drop it as refused.
    private func classifyFailure(_ error: Error, batchKeys: Set<String>) -> Outcome {
        guard let apiError = error as? KiroraApiError, !apiError.isRetryable else {
            // Offline, timed out, 429/5xx, or the token fetch failed: keep them, retry later.
            if error is UserTokenError { log.error("Events not sent", error) }
            schedule(backoff.failed(error))
            return .stop
        }
        // Still refused after a token refresh, or the user changed: keep the events for the
        // next identify() as their own user.
        if apiError.status == 401 {
            log.error("Events not sent", apiError)
            return .stop
        }
        // Too large or invalid: retry in halves until the bad event is alone, so the rest of
        // the batch still goes.
        if splitStatuses.contains(apiError.status), batchKeys.count > 1 { return .split }
        // Any other 4xx will fail every time, so drop the batch instead of blocking the queue.
        log.error(
            apiError.code == "PLAN_FEATURE_UNAVAILABLE"
                ? "Events dropped: this workspace's plan doesn't record custom events"
                : "Events dropped: Kirora refused them",
            apiError
        )
        return .settled(batchKeys)
    }

    /// The events Kirora answered for, accepted or refused. Refusals are final (the event
    /// itself is invalid), so they're logged and settled too. Anything unanswered stays.
    private func acknowledgedKeys(_ sent: JSONValue?, batchKeys: Set<String>) -> Set<String> {
        guard case .array(let results)? = sent?["results"] else { return [] }
        var settled = Set<String>()
        for result in results {
            guard let key = result["idempotencyKey"]?.stringValue, batchKeys.contains(key) else { continue }
            settled.insert(key)
            if let error = result["error"], error != .null {
                let code = error["code"]?.stringValue ?? "refused"
                let message = error["message"]?.stringValue ?? ""
                log.error("Event refused: \(code) \(message)")
            }
        }
        return settled
    }

    /// Flushes at `at`, or sooner if one is already due then, but never before the backoff.
    private func schedule(_ at: Date) {
        guard !destroyed else { return }
        let due = max(at, backoff.notBefore())
        if timerAt <= due { return }
        timer?.cancel()
        timerAt = due
        let delay = max(0, due.timeIntervalSinceNow)
        // Weak, so a client released without destroy() isn't kept alive by a long wait.
        timer = Task { [weak self] in
            await sleep(seconds: delay)
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        stopTimer()
        Task { await self.flushWhenDue() }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerAt = .distantFuture
    }
}

/// `POST /events/batch`'s body.
private struct BatchBody: Encodable, Sendable {
    let sentAt: String
    let events: [QueuedEvent]
}

/// As many events as fit the size limit, but always at least one.
private func fitBatch(_ events: [QueuedEvent]) -> [QueuedEvent] {
    let encoder = JSONEncoder()
    var bytes = envelopeBytes
    for (index, event) in events.enumerated() {
        let eventBytes = ((try? encoder.encode(event).count) ?? 0) + 1
        if bytes + eventBytes > maxBatchBytes, index > 0 { return Array(events[..<index]) }
        bytes += eventBytes
    }
    return events
}
