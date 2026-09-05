import Foundation
import StoreKit
import WebmasterID

/// Collects Apple-signed purchase evidence and submits it to WebmasterID.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHAT THIS TYPE DELIBERATELY DOES NOT DO
/// ═══════════════════════════════════════════════════════════════════════════
///
/// **It never calls `transaction.finish()`.** Finishing is the host app's
/// decision and nobody else's: it is the app that knows whether the coins were
/// granted, the subscription unlocked, the download written. An analytics SDK
/// that finished a transaction could acknowledge a purchase the app had not yet
/// delivered — and Apple would never re-offer it. There is no code path in this
/// target that calls `finish()`, and the conformance suite asserts the string
/// does not appear in the sources.
///
/// **It never decides money.** The JWS goes to the server verbatim. This type
/// does not read the price, the currency, the product type, the environment or
/// the transaction id to make any decision, and the envelope has no field to
/// put them in.
///
/// **It never trusts its own verification.** `VerificationResult` carries
/// StoreKit's local verdict, which is a client-side claim. Both `.verified` and
/// `.unverified` are submitted, because the SERVER decides — against Apple's
/// root certificates — and a client that filtered on its own verdict would
/// silently drop revenue whenever a device's trust store was stale.
public actor WebmasterIDStoreKit {
    private var configuration: WebmasterIDStoreKitConfiguration
    private var queue: WebmasterIDStoreKitQueue
    private var listener: Task<Void, Never>?
    private var isFlushing = false

    private var lastPaymentOutcome: WebmasterIDStoreKitPaymentOutcome?
    private var lastIdentityOutcome: WebmasterIDStoreKitIdentityOutcome?
    private var submitted = 0
    private var acknowledged = 0
    private var refusedIdentity = 0

    public init(configuration: WebmasterIDStoreKitConfiguration) {
        self.configuration = configuration
        self.queue = WebmasterIDStoreKitQueue(
            storage: configuration.storage,
            maxPending: configuration.maxPendingSubmissions
        )
        self.queue.load()
    }

    // ── lifecycle ────────────────────────────────────────────────────────

    /// Begin observing `Transaction.updates`.
    ///
    /// ⚠ EXACTLY ONE LISTENER, EVEN IF `start()` IS CALLED TWICE.
    ///
    /// `Transaction.updates` is a broadcast sequence: every iterator receives
    /// every update. Two listeners means every purchase is enqueued twice under
    /// two different `clientTransactionID`s, so the server sees two submissions
    /// of one payment. The payment still deduplicates on Apple's canonical key,
    /// but the queue does not, and the SDK would report double the submissions
    /// it made. A second `start()` is a no-op rather than an error, because an
    /// app that calls it from both `didFinishLaunching` and `onAppear` is
    /// making an ordinary mistake and should not crash for it.
    public func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.submit(update)
            }
        }
    }

    /// Stop observing. Queued evidence is kept, not discarded.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // ── submission ───────────────────────────────────────────────────────

    /// Submit a purchase result explicitly.
    ///
    /// The host app calls this with the `VerificationResult` from
    /// `Product.purchase`. It is not redundant with the `Transaction.updates`
    /// listener: `updates` does not deliver the transaction that a direct
    /// `purchase()` call returns in the same session, so an app relying on the
    /// listener alone would miss the purchase that just happened and only see
    /// it on the NEXT launch — and only then if it had not been finished.
    ///
    /// Submitting both is safe: the queue deduplicates on the signature.
    public func submit(_ result: VerificationResult<Transaction>) async {
        /*
         * ⚠ BOTH `.verified` AND `.unverified` ARE SUBMITTED.
         *
         * `jwsRepresentation` exists on the result itself, not only on the
         * verified payload, precisely because the signature is what matters and
         * the local verdict is advisory. A stale device trust store, a clock
         * skew, a StoreKit test configuration — any of these produce
         * `.unverified` for a payload the server will verify perfectly well.
         * Filtering here would discard real revenue on the client's guess.
         */
        await enqueue(jws: result.jwsRepresentation)
        await flushIfPossible()
    }

    /// Submit a raw signed transaction.
    ///
    /// Provided for apps that already hold a `jwsRepresentation` — from a
    /// server-side receipt refresh, say — and for the conformance suite, which
    /// must exercise the whole path on a machine with no App Store.
    public func submit(signedTransaction jws: String) async {
        await enqueue(jws: jws)
        await flushIfPossible()
    }

    private func enqueue(jws: String) async {
        /*
         * FAIL-CLOSED ON CONSENT, BEFORE ANYTHING TOUCHES DISK. Under
         * `disabled` or `notDetermined` the evidence is not queued at all —
         * writing it "just in case consent arrives" would store a purchase
         * record the user never permitted.
         */
        guard configuration.consent.permitsCollection else { return }
        guard let wire = configuration.consent.wire else { return }

        /* Bounded before storage: an oversized JWS is not evidence, it is a payload. */
        guard jws.utf8.count <= WebmasterIDStoreKitContract.maxSignedTransactionBytes else { return }

        /*
         * ⚠ THE IDENTITY CLAIM IS DROPPED HERE UNDER `restricted`, NOT SENT AND
         * LET THE SERVER DECIDE. The server does drop it — but a value that
         * never leaves the device cannot be logged by a proxy on the way.
         */
        var externalUserID: String?
        if wire.permitsPersistentIdentifiers, let claimed = configuration.externalUserID {
            externalUserID = WebmasterIDStoreKitIdentityRule.isValid(claimed) ? claimed : nil
        }

        let item = WebmasterIDStoreKitPending(
            signedTransaction: jws,
            clientTransactionID: mintClientTransactionID(),
            queuedAt: configuration.clock.now(),
            attempts: 0,
            externalUserID: externalUserID,
            consent: wire.rawValue
        )
        queue.append(item)
    }

    /// An opaque, client-minted identifier.
    ///
    /// ⚠ NOT SEEDED FROM APPLE'S TRANSACTION ID. The server echoes this back
    /// and may log it; deriving it from `transaction.id` would put an Apple
    /// transaction identifier into acknowledgements and logs.
    private func mintClientTransactionID() -> String {
        /*
         * Reuses the core's own opaque-identifier source, so this SDK has ONE
         * definition of "128 bits of system randomness, derived from nothing
         * about the device or the person". `clientEvent` is the nearest
         * existing purpose: a per-submission id whose only job is idempotency.
         */
        "sk_" + configuration.random.opaqueIdentifier(for: .clientEvent)
    }

    // ── delivery ─────────────────────────────────────────────────────────

    /// Attempt delivery of everything pending.
    ///
    /// Returns true when the queue is empty afterwards.
    @discardableResult
    public func flush() async -> Bool {
        await flushIfPossible()
        return queue.pending.isEmpty
    }

    private func flushIfPossible() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        for item in queue.pending {
            guard item.attempts < configuration.maxDeliveryAttempts else { continue }
            await deliver(item)
        }
    }

    private func deliver(_ item: WebmasterIDStoreKitPending) async {
        let submission = WebmasterIDStoreKitSubmission(
            contractVersion: WebmasterIDStoreKitContract.envelopeVersion,
            appPropertyID: configuration.appPropertyID,
            signedTransaction: item.signedTransaction,
            clientTransactionID: item.clientTransactionID,
            consent: item.consent,
            identity: item.externalUserID.map {
                WebmasterIDStoreKitSubmission.Identity(externalUserID: $0)
            }
        )

        guard let body = try? JSONEncoder().encode(submission),
            body.count <= WebmasterIDStoreKitContract.maxBodyBytes
        else { return }

        queue.recordAttempt(clientTransactionID: item.clientTransactionID)
        submitted += 1

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: WebmasterIDHTTPResponse
        do {
            response = try await configuration.transport.send(request)
        } catch {
            /* Network failure. The evidence stays; nothing is inferred from it. */
            return
        }

        /*
         * ⚠ A NON-2xx IS NOT AN ACKNOWLEDGEMENT.
         *
         * 503 is the server saying "the verifier is down" and 429 is "slow
         * down"; both mean the evidence must be kept. Only a body that decodes
         * to an acknowledgement retires anything.
         */
        guard (200...299).contains(response.status),
            let ack = try? JSONDecoder().decode(
                WebmasterIDStoreKitAcknowledgement.self, from: response.body)
        else { return }

        lastPaymentOutcome = ack.outcome
        lastIdentityOutcome = ack.identity
        acknowledged += 1
        if ack.identity == .ambiguous || ack.identity == .notPermitted { refusedIdentity += 1 }

        /*
         * ⚠ THE DISCARD RULE, AND IT IS NOT "THE PAYMENT IS TERMINAL".
         *
         * Every payment outcome is terminal, so keying on that alone would
         * always delete. A banked payment whose identity is `retryable` still
         * needs its JWS: dropping it strands the purchase unlinked forever.
         */
        if ack.mayDiscardEvidence {
            queue.remove(clientTransactionIDs: [item.clientTransactionID])
        }
    }

    // ── observation ──────────────────────────────────────────────────────

    public func setConsent(_ consent: WebmasterIDConsent) {
        configuration.consent = .decided(consent)
        /*
         * ⚠ WITHDRAWAL CLEARS THE QUEUE. Keeping signed purchase evidence after
         * the user says "stop" would be storing exactly what they withdrew
         * permission for. The purchase itself is unaffected: the host app has
         * not finished it, and Apple's own records are Apple's.
         */
        if consent == .disabled { queue.clear() }
    }

    public func identify(externalUserID: String) throws {
        guard WebmasterIDStoreKitIdentityRule.isValid(externalUserID) else {
            throw WebmasterIDValidationError.invalidExternalUserID
        }
        configuration.externalUserID = externalUserID
    }

    public func resetIdentity() {
        configuration.externalUserID = nil
    }

    public func diagnostics() -> WebmasterIDStoreKitDiagnostics {
        WebmasterIDStoreKitDiagnostics(
            isListening: listener != nil,
            pending: queue.pending.count,
            submitted: submitted,
            acknowledged: acknowledged,
            refusedForCapacity: queue.refusedForCapacity,
            identityRefusals: refusedIdentity,
            recoveredFromCorruption: queue.recoveredFromCorruption,
            lastPaymentOutcome: lastPaymentOutcome,
            lastIdentityOutcome: lastIdentityOutcome
        )
    }
}

/// Everything an integrator can see, and nothing identifying.
///
/// ⚠ NO APPLE TRANSACTION IDENTIFIERS, NO JWS, NO USER ID. Counts and closed
/// enum values only — a diagnostics struct is exactly the thing that ends up in
/// a crash report or a support ticket.
public struct WebmasterIDStoreKitDiagnostics: Sendable, Equatable {
    public let isListening: Bool
    public let pending: Int
    public let submitted: Int
    public let acknowledged: Int
    public let refusedForCapacity: Int
    public let identityRefusals: Int
    public let recoveredFromCorruption: Bool
    public let lastPaymentOutcome: WebmasterIDStoreKitPaymentOutcome?
    public let lastIdentityOutcome: WebmasterIDStoreKitIdentityOutcome?
}
