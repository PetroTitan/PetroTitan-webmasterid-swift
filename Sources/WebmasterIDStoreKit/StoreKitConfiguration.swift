import Foundation
import WebmasterID

/// How the StoreKit collector is wired.
public struct WebmasterIDStoreKitConfiguration: Sendable {
    /// The public property identifier. Not a secret and not authentication.
    public let appPropertyID: String
    public var baseURL: URL

    /// The full submission URL.
    ///
    /// Composed once here rather than at each call site, and with
    /// `appendingPathComponent` avoided deliberately: it escapes the slashes in
    /// a multi-segment path, turning `/api/v1/...` into a single encoded
    /// component and every request into a 404.
    public var endpoint: URL {
        URL(string: WebmasterIDStoreKitContract.path, relativeTo: baseURL)?.absoluteURL
            ?? baseURL
    }

    /// Consent, as the host app currently understands it.
    ///
    /// ⚠ A PURCHASE IS STILL SUBMITTED UNDER `restricted`. A verified payment is
    /// a fact about a transaction, and the merchant's own record of it; refusing
    /// to report it would lose the revenue while protecting nothing. What
    /// `restricted` removes is the IDENTITY claim — the server drops it
    /// structurally and answers `not_permitted`.
    ///
    /// Under `disabled` or `notDetermined` nothing is collected at all.
    ///
    /// ⚠ A STATE, NOT A VALUE — `.notDetermined` is a distinct case from any
    /// decision, and it is the default. Until the host app says otherwise
    /// nothing is queued, stored or sent, which is the same fail-closed rule
    /// the event client follows.
    public var consent: WebmasterIDConsentState

    /// The app's own opaque account key for the signed-in user, or nil.
    ///
    /// ⚠ NEVER AN EMAIL ADDRESS. The server refuses a value containing `@` or
    /// whitespace outright rather than hashing it, and so does this SDK before
    /// anything is queued.
    public var externalUserID: String?

    /// Bounded, because an unbounded queue is a disk-fill bug.
    public var maxPendingSubmissions: Int
    public var maxDeliveryAttempts: Int

    public var transport: any WebmasterIDTransport
    public var clock: any WebmasterIDClock
    public var random: any WebmasterIDRandomSource
    public var storage: any WebmasterIDStoreKitStorage

    public init(
        appPropertyID: String,
        baseURL: URL = URL(string: "https://api.webmasterid.com")!,
        consent: WebmasterIDConsentState = .notDetermined,
        externalUserID: String? = nil,
        maxPendingSubmissions: Int = 128,
        maxDeliveryAttempts: Int = 12,
        transport: any WebmasterIDTransport = WebmasterIDURLSessionTransport(),
        clock: any WebmasterIDClock = WebmasterIDSystemClock(),
        random: any WebmasterIDRandomSource = WebmasterIDSystemRandomSource(),
        storage: (any WebmasterIDStoreKitStorage)? = nil
    ) throws {
        self.appPropertyID = appPropertyID
        self.baseURL = baseURL
        self.consent = consent
        self.externalUserID = externalUserID
        self.maxPendingSubmissions = maxPendingSubmissions
        self.maxDeliveryAttempts = maxDeliveryAttempts
        self.transport = transport
        self.clock = clock
        self.random = random
        self.storage =
            try storage ?? WebmasterIDStoreKitFileStorage.applicationSupport(scope: appPropertyID)
    }
}

/// Whether a value may be used as an external user id.
///
/// ⚠ THE SAME RULE THE SERVER APPLIES, CHECKED HERE TOO. Not because the server
/// is untrusted, but because a client that silently sends an email address and
/// gets a 400 has already put it on the network. Refusing locally keeps it on
/// the device.
public enum WebmasterIDStoreKitIdentityRule {
    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= WebmasterIDStoreKitContract.maxExternalUserIDLength
            && !value.contains("@")
            && !value.contains(where: { $0.isWhitespace })
    }
}
