import Foundation

/// How the SDK reads each status the M3 route can return.
///
/// The route's contract is deliberately unambiguous — every outcome is a
/// distinct status, and none of them is a cheerful 2xx that means "discarded".
/// This enum is the client half of that bargain.
enum WebmasterIDDeliveryOutcome: Sendable, Equatable {
    /// 200. The batch is settled; `accepted + deduplicated` covers it.
    case settled(WebmasterIDAcknowledgement)
    /// 400. The batch is permanently invalid. Retrying it forever is a loop.
    case permanentlyInvalid
    /// 403. This property is not accepting events. Archived or unknown —
    /// deliberately indistinguishable, and this SDK must not guess which.
    case propertyRefused
    /// 413. Too large. Split, or drop the single event that cannot fit.
    case tooLarge
    /// 429. Back off for at least this long.
    case rateLimited(retryAfter: Double?)
    /// 5xx or a transport error. Retry with backoff.
    case retryable
}

enum WebmasterIDDeliveryClassifier {
    static func classify(_ response: WebmasterIDHTTPResponse) -> WebmasterIDDeliveryOutcome {
        switch response.status {
        case 200:
            /*
             * A body this SDK cannot parse is NOT treated as a failure. The
             * server answered 200, which means it stored the batch; retrying
             * because we could not read the counters would re-send work that
             * is already done. Unknown fields are ignored by the decoder, and
             * an undecodable body falls back to "all of it settled".
             */
            if let ack = try? JSONDecoder().decode(WebmasterIDAcknowledgement.self, from: response.body) {
                return .settled(ack)
            }
            return .settled(WebmasterIDAcknowledgement(accepted: 0, deduplicated: 0, rejected: 0))
        case 400: return .permanentlyInvalid
        case 403: return .propertyRefused
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: response.retryAfterSeconds)
        case 500...599: return .retryable
        default:
            /*
             * An unexpected status is retried rather than dropped. A proxy
             * returning 502 as 0, or a captive portal returning 302, is a
             * network problem — not a reason to discard a real event.
             */
            return .retryable
        }
    }
}

// ───────────────────────────────────────────────────────────────────────────
// BATCHING
// ───────────────────────────────────────────────────────────────────────────

struct WebmasterIDBatchPlan: Sendable {
    let events: [WebmasterIDQueuedEvent]
    let body: Data
}

enum WebmasterIDBatcher {
    /// Build the largest batch that fits, measured on the REAL encoded request.
    ///
    /// ═══════════════════════════════════════════════════════════════════════
    /// BYTES, NOT CHARACTERS, AND MEASURED ON THE WHOLE ENVELOPE
    /// ═══════════════════════════════════════════════════════════════════════
    ///
    /// `String.count` is grapheme clusters. A Czech screen name, an emoji in a
    /// locale tag, any non-ASCII value at all — each is 2 to 4 bytes, so a
    /// character-counted batch can be a third over the limit and get a 413 that
    /// looks like a server fault. The size is therefore the `Data.count` of the
    /// serialised envelope, including the `property_id`, the JSON punctuation
    /// and the version field, because all of that is in the request too.
    ///
    /// The search adds one event at a time and re-encodes. That is O(n²) in the
    /// batch size and it is deliberate: `maxEventsPerBatch` is 50, the cost is
    /// trivial, and the alternative — estimating per-event size and summing —
    /// is exactly the approximation that produces an off-by-a-few-bytes 413.
    static func plan(
        from events: [WebmasterIDQueuedEvent],
        propertyID: String,
        resolveUserID: (Int?) -> String?,
        limitBytes: Int = WebmasterIDContract.maxBodyBytes,
        maxCount: Int = WebmasterIDContract.maxEventsPerBatch
    ) -> WebmasterIDBatchPlan? {
        guard !events.isEmpty else { return nil }

        var chosen: [WebmasterIDQueuedEvent] = []
        var lastGoodBody: Data?

        for event in events.prefix(maxCount) {
            let candidate = chosen + [event]
            guard let body = encode(candidate, propertyID: propertyID, resolveUserID: resolveUserID) else {
                break
            }
            if body.count > limitBytes {
                /*
                 * The FIRST event already exceeds the limit on its own. It can
                 * never be delivered, at any batch size, so the caller is told
                 * with an empty plan and drops it locally rather than retrying
                 * it until the age bound expires.
                 */
                if chosen.isEmpty { return WebmasterIDBatchPlan(events: [event], body: body) }
                break
            }
            chosen = candidate
            lastGoodBody = body
        }

        guard let body = lastGoodBody, !chosen.isEmpty else { return nil }
        return WebmasterIDBatchPlan(events: chosen, body: body)
    }

    /// Deterministic split for a 413: halve the batch, never re-order it.
    ///
    /// FIFO must survive a split, so the FIRST half is retried. Halving rather
    /// than dropping one event converges in log₂(n) attempts and cannot loop:
    /// a batch of one that still 413s is the oversized-single case above.
    static func split(_ events: [WebmasterIDQueuedEvent]) -> [WebmasterIDQueuedEvent] {
        guard events.count > 1 else { return events }
        return Array(events.prefix(events.count / 2))
    }

    static func encode(
        _ events: [WebmasterIDQueuedEvent],
        propertyID: String,
        resolveUserID: (Int?) -> String?
    ) -> Data? {
        let wire = events.map { event -> WireEvent in
            /*
             * ⚠ THE RESTRICTED-CONSENT FENCE, APPLIED AT ENCODE TIME.
             *
             * Both identifiers are gated on the consent recorded ON THE EVENT,
             * not on the client's current state. An event captured under
             * `restricted` must stay identifier-free even if the user later
             * grants full analytics — the consent that governs a datum is the
             * one that was in force when it was collected.
             */
            let allowsIdentifiers = event.consent.permitsPersistentIdentifiers
            return WireEvent(
                eventID: event.clientEventID,
                eventName: event.name,
                occurredAt: WireTime.string(from: event.occurredAt),
                sessionID: event.sessionID,
                consent: event.consent,
                screen: event.context.screen,
                ctaID: event.context.ctaID,
                filterID: event.context.filterID,
                installationID: allowsIdentifiers ? event.installationID : nil,
                externalUserID: allowsIdentifiers ? resolveUserID(event.identityEpoch) : nil,
                appVersion: event.context.appVersion,
                appBuild: event.context.appBuild,
                osMajor: event.context.osMajor,
                locale: event.context.locale,
                timezone: event.context.timezone,
                actorRole: event.context.actorRole,
                eligibilityOutcome: event.context.eligibilityOutcome
            )
        }
        let envelope = WireEnvelope(
            v: WebmasterIDContract.envelopeVersion,
            propertyID: propertyID,
            events: wire
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(envelope)
    }
}

// ───────────────────────────────────────────────────────────────────────────
// BACKOFF
// ───────────────────────────────────────────────────────────────────────────

enum WebmasterIDBackoff {
    static let base: Double = 2
    static let cap: Double = 300

    /// Exponential with FULL jitter, bounded.
    ///
    /// Full jitter — a uniform draw over `[0, delay]` rather than `delay ±
    /// something` — is what stops a fleet of phones that all lost connectivity
    /// at the same moment from returning in the same synchronised wave. The cap
    /// stops the interval growing past the point where the app would be
    /// terminated before the next attempt anyway.
    static func delay(attempt: Int, random: Double) -> Double {
        let exponential = min(cap, base * pow(2, Double(max(0, attempt))))
        return exponential * min(max(random, 0), 1)
    }
}
