import Foundation
import WebmasterID

/// How the StoreKit collector is wired.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ⚠ THERE IS NO `consent` AND NO `externalUserID` HERE, AND THAT IS THE POINT
/// ═══════════════════════════════════════════════════════════════════════════
///
/// An earlier version of this type owned both. That let the analytics client
/// and the StoreKit collector hold DIFFERENT opinions about who the user was
/// and what they had agreed to — and the wrong one would win depending on which
/// object the integrator remembered to update. A purchase could be labelled
/// with an account the user had already signed out of.
///
/// Consent and identity now have exactly one authority: `WebmasterIDClient`.
/// This type carries only the transport and storage knobs.
public struct WebmasterIDStoreKitConfiguration: Sendable {
    public var baseURL: URL

    /// The full submission URL.
    ///
    /// Composed with `URL(string:relativeTo:)` rather than
    /// `appendingPathComponent`, which escapes the slashes in a multi-segment
    /// path — turning `/api/v1/…` into one encoded component and every request
    /// into a 404.
    public var endpoint: URL {
        URL(string: WebmasterIDStoreKitContract.path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    /// Bounded three ways, because an unbounded queue is a disk-fill bug and a
    /// count alone bounds nothing that matters: 128 × 16 KiB is 2 MiB.
    public var maxPendingSubmissions: Int
    public var maxQueuedBytes: Int
    public var maxEvidenceAge: TimeInterval
    public var maxDeliveryAttempts: Int

    public var transport: any WebmasterIDTransport
    public var storage: (any WebmasterIDStoreKitStorage)?

    public init(
        baseURL: URL = URL(string: "https://api.webmasterid.com")!,
        maxPendingSubmissions: Int = 128,
        maxQueuedBytes: Int = 512 * 1024,
        maxEvidenceAge: TimeInterval = 30 * 24 * 60 * 60,
        maxDeliveryAttempts: Int = 12,
        transport: any WebmasterIDTransport = WebmasterIDURLSessionTransport(),
        storage: (any WebmasterIDStoreKitStorage)? = nil
    ) {
        self.baseURL = baseURL
        self.maxPendingSubmissions = maxPendingSubmissions
        self.maxQueuedBytes = maxQueuedBytes
        /*
         * 30 days. Long enough that a phone offline for a month still reports
         * its purchase; short enough that signed evidence is not kept
         * indefinitely on a device for a delivery that is never going to
         * succeed.
         */
        self.maxEvidenceAge = maxEvidenceAge
        self.maxDeliveryAttempts = maxDeliveryAttempts
        self.transport = transport
        self.storage = storage
    }
}
