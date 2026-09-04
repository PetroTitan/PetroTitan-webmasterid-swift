import Foundation

/// What an app is allowed to see about the SDK's own state.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// EVERY FIELD IS A COUNT, A CATEGORY OR A TIME. NONE IS CONTENT.
/// ═══════════════════════════════════════════════════════════════════════════
///
/// No payloads, no event names, no identifiers, no URLs, no response bodies,
/// no request bodies, no tokens. That is not caution for its own sake:
/// diagnostics are the thing a developer prints to the console, screenshots
/// into a bug report, and forwards to a crash reporter. Anything visible here
/// should be assumed to end up in all three.
///
/// Event NAMES are excluded even though this SDK's names are a closed
/// vocabulary, because a diagnostics type outlives the assumption that made it
/// safe — the day someone adds a freer name, the leak would already be wired.
public struct WebmasterIDDiagnostics: Sendable, Equatable {
    public enum Configured: String, Sendable { case configured, notConfigured }

    /// A category, never the code — so a 403 cannot be told from a 404 by a
    /// caller reading this, which is the same guarantee the route gives.
    public enum StatusCategory: String, Sendable {
        case none, success, clientError, refused, rateLimited, serverError, transportError
    }

    public enum RetryState: Sendable, Equatable {
        case idle
        case scheduled(inSeconds: Double, attempt: Int)
        case stopped(reason: StoppedReason)
    }

    /// Why delivery stopped, in terms that disclose nothing about the property.
    ///
    /// ⚠ `propertyNotAccepting` COVERS ARCHIVED **AND** UNKNOWN. The server
    /// answers both identically on purpose — a distinguishable answer confirms
    /// that a property id is real — and an SDK that split them here would undo
    /// that at the client, where anyone with the app can read it.
    public enum StoppedReason: String, Sendable {
        case propertyNotAccepting, attemptsExhausted
    }

    public let configured: Configured
    public let consent: WebmasterIDConsent?
    public let queuedEvents: Int
    public let queuedBytes: Int
    public let lastSuccessfulDeliveryAt: Date?
    public let lastStatusCategory: StatusCategory
    public let retryState: RetryState

    // ── lifetime counters ────────────────────────────────────────────────
    public let queued: Int
    public let attempted: Int
    public let acknowledged: Int
    public let deduplicated: Int
    public let permanentlyRejected: Int
    public let droppedOversized: Int
    public let droppedExpired: Int
    public let droppedForCapacity: Int
    public let recoveredFromCorruptQueue: Bool
}
