import Foundation

/// The coarse context an app may attach to an event.
///
/// ⚠ THERE IS NO `[String: Any]` HERE, AND THERE CANNOT BE. A metadata bag on
/// a health-adjacent app is an unbounded PHI channel: no downstream scrubbing
/// recovers from having accepted "reason: knee pain", and the server refuses
/// the key anyway. Every field below is one the M3 envelope names.
public struct WebmasterIDEventContext: Sendable, Equatable {
    public var screen: String?
    public var ctaID: String?
    public var filterID: String?
    public var appVersion: String?
    public var appBuild: String?
    /// MAJOR ONLY. `18`, never `"18.3.1 (22D72)"` — a full build string is a
    /// fingerprinting surface, and the server refuses a non-integer.
    public var osMajor: Int?
    public var locale: String?
    public var timezone: String?
    public var actorRole: WebmasterIDActorRole?
    public var eligibilityOutcome: WebmasterIDEligibilityOutcome?

    public init(
        screen: String? = nil,
        ctaID: String? = nil,
        filterID: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        osMajor: Int? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        actorRole: WebmasterIDActorRole? = nil,
        eligibilityOutcome: WebmasterIDEligibilityOutcome? = nil
    ) {
        self.screen = screen
        self.ctaID = ctaID
        self.filterID = filterID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osMajor = osMajor
        self.locale = locale
        self.timezone = timezone
        self.actorRole = actorRole
        self.eligibilityOutcome = eligibilityOutcome
    }
}

/// One logical event, as it sits in the durable queue.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHAT THIS DOES NOT HOLD, AND WHY THE ABSENCE IS STRUCTURAL
/// ═══════════════════════════════════════════════════════════════════════════
///
/// It holds no external user identifier. That is not an oversight and not a
/// filter — the field does not exist on this type, so the queue file that
/// serialises it cannot contain one.
///
/// An authenticated user id is a direct identifier. Writing it in plaintext
/// into a JSON file in the app container would mean every queued event carried
/// a durable account key on disk, readable by anything with file access and
/// surviving until delivery. Instead the event records `identityEpoch`, an
/// opaque local counter, and the raw value lives in `IdentityStore` — Keychain
/// on Apple platforms, injectable in tests. At encode time the epoch is
/// resolved against the CURRENT identity: an event queued before a logout
/// resolves to nothing, which is also the privacy-correct answer.
struct WebmasterIDQueuedEvent: Sendable, Codable, Equatable {
    /// The idempotency key. Generated ONCE, at `track`, and never regenerated.
    let clientEventID: String
    let name: WebmasterIDEventName
    /// When it HAPPENED. A retry never replaces this with the delivery time.
    let occurredAt: Date
    let sessionID: String
    let consent: WebmasterIDConsent
    /// Present only when consent permitted a persistent identifier at track time.
    let installationID: String?
    /// An opaque handle, never a user id. See the type comment.
    let identityEpoch: Int?
    let context: WebmasterIDEventContext

    enum CodingKeys: String, CodingKey {
        case clientEventID = "cid"
        case name = "n"
        case occurredAt = "t"
        case sessionID = "s"
        case consent = "c"
        case installationID = "i"
        case identityEpoch = "e"
        case context = "x"
    }
}

extension WebmasterIDEventContext: Codable {
    enum CodingKeys: String, CodingKey {
        case screen, ctaID, filterID, appVersion, appBuild
        case osMajor, locale, timezone, actorRole, eligibilityOutcome
    }
}

// ───────────────────────────────────────────────────────────────────────────
// THE WIRE SHAPE
// ───────────────────────────────────────────────────────────────────────────

/// One event as the ingest route reads it.
///
/// ⚠ THE CODING KEYS ARE THE CONTRACT. They are written out rather than
/// derived from a key-encoding strategy, because `.convertToSnakeCase` would
/// turn `ctaID` into `cta_i_d` and `osMajor` into `os_major` — one right, one
/// wrong, and nothing would say which. The golden fixtures catch the rest.
struct WireEvent: Encodable, Sendable {
    let eventID: String
    let eventName: WebmasterIDEventName
    let occurredAt: String
    let sessionID: String
    let consent: WebmasterIDConsent
    let screen: String?
    let ctaID: String?
    let filterID: String?
    let installationID: String?
    let externalUserID: String?
    let appVersion: String?
    let appBuild: String?
    let osMajor: Int?
    let locale: String?
    let timezone: String?
    let actorRole: WebmasterIDActorRole?
    let eligibilityOutcome: WebmasterIDEligibilityOutcome?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventName = "event_name"
        case occurredAt = "occurred_at"
        case sessionID = "session_id"
        case consent
        case screen
        case ctaID = "cta_id"
        case filterID = "filter_id"
        case installationID = "installation_id"
        case externalUserID = "external_user_id"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case osMajor = "os_major"
        case locale
        case timezone
        case actorRole = "actor_role"
        case eligibilityOutcome = "eligibility_outcome"
    }

    /// ⚠ `encodeIfPresent` THROUGHOUT, DELIBERATELY.
    ///
    /// Swift's synthesised encoder writes `"screen": null` for a nil optional.
    /// The server's allowlist accepts the KEY and then validates its value, so
    /// an explicit null is a key we sent for no reason — and for `installation_id`
    /// under restricted consent it would put a forbidden key on the wire whose
    /// absence is the whole guarantee. Nothing nil is ever emitted.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(eventName, forKey: .eventName)
        try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(consent, forKey: .consent)
        try c.encodeIfPresent(screen, forKey: .screen)
        try c.encodeIfPresent(ctaID, forKey: .ctaID)
        try c.encodeIfPresent(filterID, forKey: .filterID)
        try c.encodeIfPresent(installationID, forKey: .installationID)
        try c.encodeIfPresent(externalUserID, forKey: .externalUserID)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
        try c.encodeIfPresent(appBuild, forKey: .appBuild)
        try c.encodeIfPresent(osMajor, forKey: .osMajor)
        try c.encodeIfPresent(locale, forKey: .locale)
        try c.encodeIfPresent(timezone, forKey: .timezone)
        try c.encodeIfPresent(actorRole, forKey: .actorRole)
        try c.encodeIfPresent(eligibilityOutcome, forKey: .eligibilityOutcome)
    }
}

struct WireEnvelope: Encodable, Sendable {
    let v: Int
    let propertyID: String
    let events: [WireEvent]

    enum CodingKeys: String, CodingKey {
        case v
        case propertyID = "property_id"
        case events
    }
}

/// The route's 200 body.
///
/// Decoded leniently on purpose: a field this SDK does not know about must not
/// turn a successful delivery into a parse failure, because the client would
/// then retry work the server already stored. Unknown keys are IGNORED on the
/// way in and IMPOSSIBLE on the way out — the asymmetry is the forward
/// compatibility rule.
public struct WebmasterIDAcknowledgement: Sendable, Decodable, Equatable {
    public let accepted: Int
    public let deduplicated: Int
    public let rejected: Int

    enum CodingKeys: String, CodingKey {
        case accepted, deduplicated, rejected
    }

    public init(accepted: Int, deduplicated: Int, rejected: Int) {
        self.accepted = accepted
        self.deduplicated = deduplicated
        self.rejected = rejected
    }

    /// Every event we offered was accounted for, one way or the other.
    public var settled: Int { accepted + deduplicated }
}

// ───────────────────────────────────────────────────────────────────────────
// TIME
// ───────────────────────────────────────────────────────────────────────────

enum WireTime {
    /// ISO-8601 with a `Z` offset and milliseconds, which is what the route's
    /// regex accepts. Built once; `ISO8601DateFormatter` is thread-safe for
    /// formatting and this instance is never mutated after construction.
    /*
     * ⚠ `nonisolated(unsafe)`, WITH THE REASON WRITTEN DOWN.
     *
     * `ISO8601DateFormatter` is not `Sendable`, so Swift 6 refuses a shared
     * static. It IS documented thread-safe for formatting and parsing, and
     * this instance is configured once inside the initialiser and never
     * mutated afterwards — no property is set on it from anywhere else in the
     * package. The alternative, constructing a formatter per event, costs a
     * measurable allocation on every single track() for no safety gain.
     */
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}
