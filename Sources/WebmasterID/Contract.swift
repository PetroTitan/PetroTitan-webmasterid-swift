import Foundation

/// M4 — the wire contract, mirrored from the M3 ingest route.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// EVERY VALUE HERE HAS A COUNTERPART THE SERVER ENFORCES
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Nothing in this file is a preference. Each limit, key name and vocabulary
/// is copied from the ingest service's own wire-format module, and the golden
/// JSON fixtures in `Sources/WebmasterIDConformance/Fixtures/` are validated by
/// BOTH sides — the service parses them and this SDK encodes them — so the two
/// contracts cannot drift apart quietly. A field the route does not accept is
/// not a field this SDK can send, because there is nowhere to put it.
public enum WebmasterIDContract {
    /// Wire-format version. The server refuses anything else rather than coercing.
    public static let envelopeVersion = 1

    public static let maxEventsPerBatch = 50
    public static let minEventsPerBatch = 1

    /// The route's own `bodyLimit`. Measured in UTF-8 BYTES, never characters.
    public static let maxBodyBytes = 48 * 1024

    /// The server refuses an event older than this outright — it does not clamp it.
    public static let maxEventAge: TimeInterval = 7 * 24 * 60 * 60

    /// How far ahead a device clock may be before the server stops believing it.
    public static let maxClockSkew: TimeInterval = 10 * 60

    public static let maxSessionIDLength = 64
    public static let maxInstallationIDLength = 64
    public static let maxExternalUserIDLength = 128
    public static let maxScreenLength = 64
    public static let maxIdentifierLength = 64
    public static let maxAppVersionLength = 32

    /// The production ingest origin.
    public static let defaultBaseURL = URL(string: "https://api.webmasterid.com")!
    public static let path = "/api/v1/mobile/events"
}

// ───────────────────────────────────────────────────────────────────────────
// EVENT NAMES
// ───────────────────────────────────────────────────────────────────────────

/// The closed set of event names the ingest route accepts.
///
/// ⚠ A CLOSED ENUM, NOT A STRING. An open `String` parameter is how a name
/// like `"search:knee pain"` or `"signup_dr_smith"` reaches a server: not
/// because anyone decided to send it, but because the type allowed it and a
/// hurried caller interpolated. There is no `case other(String)` here, and
/// adding one would defeat the point.
public enum WebmasterIDEventName: String, Sendable, CaseIterable, Codable {
    case appOpen = "app_open"
    case sessionStart = "session_start"
    case screenView = "screen_view"
    case ctaTap = "cta_tap"
    case searchPerformed = "search_performed"
    case filterApplied = "filter_applied"
    case signup
    case login
    case checkoutStarted = "checkout_started"
    case bookingStarted = "booking_started"
    case paymentStarted = "payment_started"
    case bookingCompleted = "booking_completed"
    case cancellation
    case refundRequested = "refund_requested"

    /// `app_open` and `session_start` happen before any screen is presented,
    /// and the server refuses a screen on either. Not "need not carry one" —
    /// must not.
    var permitsScreen: Bool {
        switch self {
        case .appOpen, .sessionStart: return false
        default: return true
        }
    }
}

// ───────────────────────────────────────────────────────────────────────────
// CONSENT
// ───────────────────────────────────────────────────────────────────────────

/// The server's three-state consent contract, mirrored exactly.
///
/// ⚠ THERE IS NO `unknown` CASE THAT MEANS "PROCEED". The SDK's own starting
/// state is `.notDetermined`, which collects nothing at all and is never sent;
/// the three cases below are the only values that can reach the wire, and the
/// server refuses `disabled` as a payload. A fourth state meaning "we did not
/// ask" would eventually be treated as permission by someone reading a
/// truth-table.
public enum WebmasterIDConsent: String, Sendable, Codable, CaseIterable {
    /// Full analytics, including pseudonymous persistent identifiers.
    case analyticsAllowed = "analytics_allowed"
    /// Events only. No installation id, no external user id, no stable identifier.
    case restricted
    /// Nothing is collected, queued or sent, and prohibited state is cleared.
    case disabled

    /// Whether a persistent pseudonymous identifier may be created, stored or sent.
    var permitsPersistentIdentifiers: Bool { self == .analyticsAllowed }
    /// Whether an event may be created at all.
    var permitsCollection: Bool { self != .disabled }
}

/// What the SDK knows about consent, including "nobody has told us".
public enum WebmasterIDConsentState: Sendable, Equatable {
    case notDetermined
    case decided(WebmasterIDConsent)

    var wire: WebmasterIDConsent? {
        if case let .decided(value) = self { return value }
        return nil
    }

    /// ⚠ FAIL-CLOSED. Until the host application says otherwise, nothing is
    /// collected — not queued, not stored, not sent. The web tracker's own
    /// consent vocabulary is fail-OPEN, which is right for a cookieless page
    /// count and wrong for an app that had to ask.
    var permitsCollection: Bool { wire?.permitsCollection ?? false }
    var permitsPersistentIdentifiers: Bool { wire?.permitsPersistentIdentifiers ?? false }
}

// ───────────────────────────────────────────────────────────────────────────
// COARSE CONTEXT VOCABULARIES
// ───────────────────────────────────────────────────────────────────────────

/// Who is acting, coarsely. No free text, no job titles, no names.
public enum WebmasterIDActorRole: String, Sendable, Codable, CaseIterable {
    case consumer, provider, staff, guest
}

/// Whether a flow's gate opened — deliberately never WHY.
///
/// "Why was this person ineligible" is the question whose answer would be a
/// health fact, so the vocabulary cannot express it.
public enum WebmasterIDEligibilityOutcome: String, Sendable, Codable, CaseIterable {
    case eligible, ineligible, undetermined
}

// ───────────────────────────────────────────────────────────────────────────
// WHAT THE SDK REFUSES TO CARRY
// ───────────────────────────────────────────────────────────────────────────

/// Reasons an event is refused locally, before it can ever be queued.
///
/// Refusing here rather than at the server is not duplication: an event the
/// server would reject is one the queue would carry, retry and eventually drop,
/// and the developer would see nothing until a dashboard was empty.
public enum WebmasterIDValidationError: Error, Sendable, Equatable {
    case screenNotPermittedForEvent(WebmasterIDEventName)
    case invalidScreen
    case invalidControlIdentifier
    case controlIdentifierNotPermittedForEvent(WebmasterIDEventName)
    case invalidAppVersion
    case invalidOSMajor
    case invalidLocale
    case invalidTimezone
    case invalidExternalUserID
    case eventTooLargeToSend
}
