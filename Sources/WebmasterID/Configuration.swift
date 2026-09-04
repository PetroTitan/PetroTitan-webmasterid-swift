import Foundation

/// How a client is set up.
///
/// ⚠ THERE IS NO API KEY, NO SECRET AND NO TOKEN, AND THAT IS THE DESIGN.
/// The app property identifier travels inside an app binary that anyone can
/// download and unzip. It is an ADDRESSING token, not a credential, and the
/// server treats it as public: an unknown and an archived property get the
/// same answer precisely so that holding one proves nothing. Adding a "secret"
/// here would not add security — it would ship a secret to every user of the
/// app and create the false impression that the endpoint is authenticated.
public struct WebmasterIDConfiguration: Sendable {
    /// `ap_` + 16 lowercase alphanumerics. Public.
    public let appPropertyID: String
    /// Defaults to production. Overridden in tests and for a local route.
    public var baseURL: URL
    /// The starting consent state. `.notDetermined` collects nothing.
    public var consent: WebmasterIDConsentState
    /// An account key the host supplies. NEVER inferred, never an email.
    public var externalUserID: String?

    // ── bounds ───────────────────────────────────────────────────────────
    /// The per-request byte budget.
    ///
    /// ⚠ THE DEFAULT IS THE SERVER'S 48 KiB, AND IT IS UNREACHABLE BY VALID
    /// EVENTS. Every field the envelope accepts is bounded — a 64-character
    /// session id, a 64-character screen, a 128-character account key — so
    /// fifty maximal events come to roughly 25 KiB. The byte check is
    /// therefore defensive rather than load-bearing today.
    ///
    /// It is settable for two real reasons: a host on a metered connection may
    /// want smaller requests, and the byte-accurate splitting can then be
    /// EXERCISED rather than merely written. A mutation test that lowers this
    /// is how "measured in UTF-8 bytes, not characters" is proven at all — with
    /// the default it is unfalsifiable.
    public var maxBatchBytes: Int
    public var maxQueuedEvents: Int
    public var maxQueuedBytes: Int
    public var maxEventAge: TimeInterval
    public var maxDeliveryAttempts: Int

    // ── injected seams ───────────────────────────────────────────────────
    public var transport: any WebmasterIDTransport
    public var clock: any WebmasterIDClock
    public var random: any WebmasterIDRandomSource
    public var storage: any WebmasterIDStorage
    public var identityStore: any WebmasterIDIdentityStore

    public init(
        appPropertyID: String,
        baseURL: URL = WebmasterIDContract.defaultBaseURL,
        consent: WebmasterIDConsentState = .notDetermined,
        externalUserID: String? = nil,
        maxBatchBytes: Int = WebmasterIDContract.maxBodyBytes,
        maxQueuedEvents: Int = 1_000,
        maxQueuedBytes: Int = 512 * 1024,
        maxEventAge: TimeInterval = WebmasterIDContract.maxEventAge,
        maxDeliveryAttempts: Int = 8,
        transport: (any WebmasterIDTransport)? = nil,
        clock: any WebmasterIDClock = WebmasterIDSystemClock(),
        random: any WebmasterIDRandomSource = WebmasterIDSystemRandomSource(),
        storage: (any WebmasterIDStorage)? = nil,
        identityStore: (any WebmasterIDIdentityStore)? = nil
    ) throws {
        self.appPropertyID = appPropertyID
        self.baseURL = baseURL
        self.consent = consent
        self.externalUserID = externalUserID
        self.maxBatchBytes = min(maxBatchBytes, WebmasterIDContract.maxBodyBytes)
        self.maxQueuedEvents = maxQueuedEvents
        self.maxQueuedBytes = maxQueuedBytes
        self.maxEventAge = maxEventAge
        self.maxDeliveryAttempts = maxDeliveryAttempts
        self.transport = transport ?? WebmasterIDURLSessionTransport()
        self.clock = clock
        self.random = random
        self.storage = try storage ?? WebmasterIDFileStorage.applicationSupport(scope: appPropertyID)
        self.identityStore = identityStore ?? Self.defaultIdentityStore(scope: appPropertyID)
    }

    private static func defaultIdentityStore(scope: String) -> any WebmasterIDIdentityStore {
        #if canImport(Security)
        return WebmasterIDKeychainIdentityStore(scope: scope)
        #else
        return WebmasterIDMemoryIdentityStore()
        #endif
    }

    /// Where events are posted.
    ///
    /// Public because a host application legitimately needs it: to configure
    /// App Transport Security for a non-production origin, to point a debug
    /// proxy at it, or to assert in its own tests that it is talking to the
    /// environment it thinks it is.
    public var endpoint: URL {
        /*
         * `appendingPathComponent` would percent-escape a path that already
         * contains slashes into one segment. The path is a constant, so it is
         * appended to the string form and re-parsed.
         */
        URL(string: baseURL.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            + WebmasterIDContract.path) ?? baseURL
    }
}
