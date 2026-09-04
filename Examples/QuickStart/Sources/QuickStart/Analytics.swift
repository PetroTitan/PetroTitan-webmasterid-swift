import Foundation
import WebmasterID

/// A worked integration, written the way an app would write it.
///
/// ⚠ EVERY IDENTIFIER HERE IS A PLACEHOLDER. `ap_xxxxxxxxxxxxxxxx` is not a
/// real property, `acct_placeholder` is not a real account. Documentation and
/// examples are copied into real projects, and a real value in one becomes a
/// real value in a hundred repositories.
///
/// ⚠ AND THERE IS NO SECRET TO PUT HERE. The app property id is PUBLIC — it
/// ships inside the binary and anyone can read it out. WebmasterID's ingest
/// route treats it as an address, not a credential, which is why an unknown
/// and an archived property get identical answers.
public enum Analytics {
    /// Replace with your own property id from the WebmasterID dashboard.
    public static let appPropertyID = "ap_xxxxxxxxxxxxxxxx"

    /// One client for the process. An app may hold several; there is no shared
    /// singleton, and nothing here is `static var`.
    public static func makeClient() throws -> WebmasterIDClient {
        WebmasterIDClient(
            configuration: try WebmasterIDConfiguration(
                appPropertyID: appPropertyID,
                // `consent` defaults to `.notDetermined`, which collects
                // NOTHING — no event is queued, sent or stored, and no
                // persistent identifier is created — until the app decides.
                consent: .notDetermined
            )
        )
    }
}

/// Where an integration mistake surfaces.
///
/// `track` throws only when the CALLER got something wrong — a screen on an
/// `app_open`, a sentence where a symbol belongs. A lifecycle hook cannot
/// propagate, so it has to decide, and the two wrong decisions are obvious:
/// crashing a shipped app over analytics, or discarding the one signal that
/// would have told the developer their integration is silently doing nothing.
///
/// So it is loud in development and quiet in production. Replace it if your
/// app has a better place to send this.
public enum AnalyticsFailure {
    public static func report(_ error: Error, from context: StaticString) {
        #if DEBUG
        assertionFailure("WebmasterID \(context): \(error)")
        #else
        _ = (error, context)
        #endif
    }
}

/// The lifecycle an app forwards. Kept UI-framework-free on purpose: the SDK
/// performs no swizzling and observes nothing on its own, so an app decides
/// when these happen.
public struct AnalyticsLifecycle: Sendable {
    private let client: WebmasterIDClient

    public init(client: WebmasterIDClient) { self.client = client }

    /// Call once the person has answered your consent prompt.
    public func grantAnalytics() async {
        await client.setConsent(.analyticsAllowed)
    }

    /// Events only — no installation id, no account key, nothing stable.
    public func restrict() async {
        await client.setConsent(.restricted)
    }

    /// Stops collection AND deletes what was collected: the queue is emptied,
    /// the installation id is forgotten and the stored account key is removed.
    public func disable() async {
        await client.setConsent(.disabled)
    }

    /// After an authenticated login. Pass YOUR opaque account key — never an
    /// email address, which the SDK refuses rather than hashes.
    public func signedIn(accountKey: String) async throws {
        try await client.identify(externalUserID: accountKey)
    }

    /// On logout or an account switch. Forgets the account key and starts a
    /// new pseudonymous identity.
    public func signedOut() async {
        await client.resetIdentity()
    }

    /*
     * ═══════════════════════════════════════════════════════════════════════
     * WHY THESE `throws` INSTEAD OF SWALLOWING THE ERROR
     * ═══════════════════════════════════════════════════════════════════════
     *
     * These three were written as `try? await client.track(…)`, which reads
     * like defensiveness and is not. `track` throws only for a validation
     * mistake the CALLER made — a screen on an `app_open`, a `cta_id` on
     * something that is not a tap, a screen name that is a sentence rather
     * than a symbol. Every one of those is a bug in the integration, and
     * every one of them is silent under `try?`: the developer sees no error,
     * the dashboard stays empty, and nothing connects the two.
     *
     * It never throws because the network is down, the queue is full or the
     * server is unhappy. Those are handled internally and reported through
     * `diagnostics()`. So there is nothing here that an app should shrug off.
     *
     * `try?` also produced an unused `Bool?` — `track` is
     * `@discardableResult` — which is the warning that blocked CI before it
     * ever reached the iOS build.
     */
    public func openedApp() async throws {
        await client.applicationDidBecomeActive()
        try await client.track(.appOpen)
    }

    public func viewed(screen: String) async throws {
        try await client.track(.screenView, context: .init(screen: screen))
    }

    public func tapped(cta: String, on screen: String) async throws {
        try await client.track(.ctaTap, context: .init(screen: screen, ctaID: cta))
    }

    /// Deliver what is queued now. Anything undelivered stays on disk and is
    /// retried later; this does not block and does not guarantee delivery.
    public func flush() async {
        await client.flush()
    }

    public func enteredBackground() async {
        await client.applicationDidEnterBackground()
    }

    /// Privacy-safe: counts, categories and times. No payloads, no
    /// identifiers, no URLs.
    public func troubleshoot() async -> String {
        let d = await client.diagnostics()
        return "queued=\(d.queuedEvents) bytes=\(d.queuedBytes) status=\(d.lastStatusCategory.rawValue)"
    }
}
