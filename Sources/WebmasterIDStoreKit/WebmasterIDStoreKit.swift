import Foundation
import StoreKit
import WebmasterID

/// Collects Apple-signed purchase evidence and submits it to WebmasterID.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHAT THIS TYPE DELIBERATELY DOES NOT DO
/// ═══════════════════════════════════════════════════════════════════════════
///
/// **It never calls `transaction.finish()`.** Apple's contract puts finishing on
/// the application, after the product or service has actually been delivered.
/// Only the app knows whether the coins were granted or the download written. An
/// analytics SDK that finished a transaction would acknowledge a purchase the
/// app had not delivered, and Apple would never re-offer it. There is no code
/// path here that calls it, and the conformance suite asserts the sources
/// contain no such call once comments are stripped.
///
/// **It never decides money.** The JWS goes to the server verbatim. Nothing here
/// reads the price, currency, product type, environment or transaction id to
/// make a decision, and the envelope has no field to carry them.
///
/// **It never owns consent or identity.** Both belong to `WebmasterIDClient`,
/// which is why this type is constructed FROM one rather than configured beside
/// one. Two objects with independent opinions about who the user is will
/// eventually disagree, and the purchase is the record that gets it wrong.
///
/// **It never stores a raw account key.** The queue holds an identity EPOCH.
/// The raw value is resolved from the core at delivery, and only if that
/// identity is still current.
public actor WebmasterIDStoreKit {
    private let analytics: WebmasterIDClient
    private var configuration: WebmasterIDStoreKitConfiguration
    private var queue: WebmasterIDStoreKitQueue
    private var listener: Task<Void, Never>?
    /// Incremented once per iterator actually created — never per `start()` call.
    private var listenerGeneration = 0
    private var isFlushing = false

    /// The core's last known state. Pushed on every change, never guessed.
    private var context: WebmasterIDExtensionContext

    private var lastPaymentOutcome: WebmasterIDStoreKitPaymentOutcome?
    private var lastIdentityOutcome: WebmasterIDStoreKitIdentityOutcome?
    private var lastEnqueueOutcome: WebmasterIDStoreKitEnqueueOutcome?
    private var submitted = 0
    private var acknowledged = 0
    private var unverifiedRefused = 0
    private var retryAfterHonoured = 0
    private var notBefore: Date?

    private let clock: any WebmasterIDClock
    private let random: any WebmasterIDRandomSource
    private var storage: any WebmasterIDStoreKitStorage

    /// Construct, then attach — the only supported way to build one.
    ///
    /// ⚠ TWO STEPS, BECAUSE AN ACTOR'S `async` INITIALISER IS ACTOR-ISOLATED
    /// AND CANNOT BE CALLED FROM OUTSIDE IT. The compiler said so. Attaching
    /// needs to read the core client's state, which is a cross-actor `await`,
    /// so it cannot happen in the initialiser.
    ///
    /// The synchronous initialiser leaves this object FAIL-CLOSED —
    /// `.notDetermined`, no storage, nothing collected — so an object that was
    /// somehow used before `attach()` refuses everything rather than guessing.
    public static func attached(
        to analyticsClient: WebmasterIDClient,
        configuration: WebmasterIDStoreKitConfiguration = WebmasterIDStoreKitConfiguration(),
        clock: any WebmasterIDClock = WebmasterIDSystemClock(),
        random: any WebmasterIDRandomSource = WebmasterIDSystemRandomSource()
    ) async throws -> WebmasterIDStoreKit {
        let collector = WebmasterIDStoreKit(
            analyticsClient: analyticsClient,
            configuration: configuration,
            clock: clock,
            random: random
        )
        try await collector.attach()
        return collector
    }

    /// ⚠ NOT PUBLIC. `attached(to:)` is the entry point; a half-built collector
    /// is not something a host should be able to hold.
    private init(
        analyticsClient: WebmasterIDClient,
        configuration: WebmasterIDStoreKitConfiguration,
        clock: any WebmasterIDClock,
        random: any WebmasterIDRandomSource
    ) {
        self.analytics = analyticsClient
        self.configuration = configuration
        self.clock = clock
        self.random = random
        let unattached = WebmasterIDStoreKitUnattachedStorage()
        self.storage = unattached
        self.queue = WebmasterIDStoreKitQueue(
            storage: unattached,
            maxPending: configuration.maxPendingSubmissions,
            maxBytes: configuration.maxQueuedBytes,
            maxAge: configuration.maxEvidenceAge
        )
        /* Fail-closed until the core says otherwise. */
        self.context = WebmasterIDExtensionContext(consent: .notDetermined, identityEpoch: 0)
    }

    private func attach() async throws {
        let propertyScope = await analytics.packageAppPropertyID
        let resolved =
            try configuration.storage
            ?? WebmasterIDStoreKitFileStorage.applicationSupport(scope: propertyScope)
        storage = resolved
        var loaded = WebmasterIDStoreKitQueue(
            storage: resolved,
            maxPending: configuration.maxPendingSubmissions,
            maxBytes: configuration.maxQueuedBytes,
            maxAge: configuration.maxEvidenceAge
        )
        loaded.load(now: clock.now())
        queue = loaded
        context = await analytics.extensionContext()
        /*
         * Registered AFTER the queue is loaded, so the first pushed state acts
         * on what is actually stored — including deleting it if consent was
         * withdrawn since the last launch.
         */
        await analytics.registerExtensionObserver(self)
    }

    // ── lifecycle ────────────────────────────────────────────────────────

    /// Begin observing `Transaction.updates`.
    ///
    /// ⚠ EXACTLY ONE ITERATOR, HOWEVER MANY TIMES THIS IS CALLED.
    ///
    /// `Transaction.updates` is a broadcast sequence: every iterator receives
    /// every update. Two iterators means every purchase is queued twice under
    /// two `clientTransactionID`s, so one payment reaches the server as two
    /// submissions. A repeat call is a no-op rather than an error, because an
    /// app calling it from both `didFinishLaunching` and `onAppear` is making an
    /// ordinary mistake and should not crash for it.
    public func start() {
        guard listener == nil else { return }
        listenerGeneration += 1
        listener = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.submit(update)
            }
        }
    }

    /// Stop observing. ⚠ QUEUED EVIDENCE IS KEPT, NOT DISCARDED.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // ── submission ───────────────────────────────────────────────────────

    /// Submit a purchase result explicitly.
    ///
    /// Call this with the `VerificationResult` from `Product.purchase`. It is
    /// not redundant with the `Transaction.updates` listener: `updates` does not
    /// deliver the transaction a direct `purchase()` returns in the same
    /// session, so relying on the listener alone misses the purchase that just
    /// happened. Submitting through both paths is safe — the queue deduplicates
    /// on the signature.
    @discardableResult
    public func submit(
        _ result: VerificationResult<Transaction>
    ) async -> WebmasterIDStoreKitEnqueueOutcome {
        /*
         * ⚠ ONLY `.verified` IS SUBMITTED.
         *
         * `.unverified` means StoreKit itself could not vouch for the payload on
         * this device. Sending it anyway would push a payload the client already
         * knows is untrustworthy at a server that must then spend verification
         * work refusing it, and would make "how many payments did we report"
         * depend on device trust-store health.
         *
         * ⚠ THIS IS NOT A SUBSTITUTE FOR SERVER VERIFICATION. Every submitted
         * JWS is still verified server-side against Apple's root certificates.
         * The local check narrows what is sent; it never decides what is
         * trusted.
         *
         * Apple's error is NOT retained or logged — only a count.
         */
        guard case .verified = result else {
            unverifiedRefused += 1
            lastEnqueueOutcome = .refusedUnverified
            return .refusedUnverified
        }
        /*
         * ⚠ THE JWS COMES FROM THE RESULT, NOT THE PAYLOAD.
         *
         * `jwsRepresentation` is a property of `VerificationResult`, not of
         * `Transaction` — the compiler said so. That is the right shape: the
         * signature belongs to the envelope Apple handed over, and the decoded
         * payload is only what StoreKit made of it. The guard above decides
         * WHETHER to send; the bytes sent are always the original envelope.
         */
        let outcome = enqueue(jws: result.jwsRepresentation)
        await flushIfPossible()
        return outcome
    }

    /// Submit a `Product.PurchaseResult` directly.
    ///
    /// A convenience so the common path reads the way the App Store API does.
    /// `.pending` and `.userCancelled` are not purchases and are not queued.
    @discardableResult
    public func submit(
        _ result: Product.PurchaseResult
    ) async -> WebmasterIDStoreKitEnqueueOutcome? {
        guard case let .success(verification) = result else { return nil }
        return await submit(verification)
    }

    /// Attempt delivery of everything pending. True when the queue is empty.
    @discardableResult
    public func flush() async -> Bool {
        await flushIfPossible()
        return queue.deliverable.isEmpty
    }

    private func enqueue(jws: String) -> WebmasterIDStoreKitEnqueueOutcome {
        /*
         * FAIL-CLOSED ON CONSENT, BEFORE ANYTHING TOUCHES DISK. Under `disabled`
         * or `notDetermined` nothing is stored — writing it "in case consent
         * arrives" would keep a purchase record the user never permitted.
         */
        guard context.permitsCollection else {
            lastEnqueueOutcome = .refusedByConsent
            return .refusedByConsent
        }
        guard let wire = context.consent.wire else {
            lastEnqueueOutcome = .refusedByConsent
            return .refusedByConsent
        }
        guard jws.utf8.count <= WebmasterIDStoreKitContract.maxSignedTransactionBytes else {
            lastEnqueueOutcome = .refusedTooLarge
            return .refusedTooLarge
        }

        /*
         * ⚠ THE EPOCH, NOT THE USER. Under `restricted` no identity is captured
         * at all, so there is nothing to resolve later either.
         */
        let epoch: Int? = context.permitsPersistentIdentifiers ? context.identityEpoch : nil

        let item = WebmasterIDStoreKitPending(
            signedTransaction: jws,
            clientTransactionID: mintClientTransactionID(),
            queuedAt: clock.now(),
            attempts: 0,
            identityEpoch: epoch,
            consent: wire.rawValue
        )
        let outcome = queue.append(item, now: clock.now())
        lastEnqueueOutcome = outcome
        return outcome
    }

    /// An opaque, client-minted identifier.
    ///
    /// ⚠ NOT SEEDED FROM APPLE'S TRANSACTION ID. The server echoes this back and
    /// may log it; deriving it from `transaction.id` would put an Apple
    /// transaction identifier into acknowledgements and logs.
    private func mintClientTransactionID() -> String {
        "sk_" + random.opaqueIdentifier(for: .clientEvent)
    }

    // ── delivery ─────────────────────────────────────────────────────────

    private func flushIfPossible() async {
        /* Single-flight: two concurrent flushes would send the same item twice. */
        guard !isFlushing else { return }
        guard context.permitsCollection else { return }
        if let notBefore, clock.now() < notBefore { return }
        isFlushing = true
        defer { isFlushing = false }

        queue.pruneExpired(now: clock.now())
        for item in queue.deliverable {
            if Task.isCancelled { return }
            if let notBefore, clock.now() < notBefore { return }
            await deliver(item)
        }
    }

    private func deliver(_ item: WebmasterIDStoreKitPending) async {
        /*
         * ⚠ THE RAW ACCOUNT KEY IS RESOLVED HERE, TRANSIENTLY, AND ONLY IF THE
         * IDENTITY IS STILL THE ONE THAT WAS CURRENT WHEN THIS WAS QUEUED.
         *
         * After a sign-out, a reset or an account switch the core returns nil
         * and this purchase is delivered with no user at all. It is never
         * relabelled with whoever happens to be signed in now.
         */
        let externalUserID = await analytics.resolveExternalUserID(forEpoch: item.identityEpoch)

        let submission = WebmasterIDStoreKitSubmission(
            contractVersion: WebmasterIDStoreKitContract.envelopeVersion,
            appPropertyID: await analytics.packageAppPropertyID,
            signedTransaction: item.signedTransaction,
            clientTransactionID: item.clientTransactionID,
            consent: item.consent,
            identity: externalUserID.map {
                WebmasterIDStoreKitSubmission.Identity(externalUserID: $0)
            }
        )

        guard let body = try? JSONEncoder().encode(submission),
            body.count <= WebmasterIDStoreKitContract.maxBodyBytes
        else { return }

        queue.recordAttempt(
            clientTransactionID: item.clientTransactionID,
            ceiling: configuration.maxDeliveryAttempts
        )
        submitted += 1

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: WebmasterIDHTTPResponse
        do {
            response = try await configuration.transport.send(request)
        } catch {
            /* Transport failure. The evidence stays; nothing is inferred. */
            backOff(after: item)
            return
        }

        /*
         * ⚠ A NON-2xx IS NOT AN ACKNOWLEDGEMENT.
         *
         * 503 means the verifier is down and 429 means slow down; both mean keep
         * the evidence. An unrecognised status is treated the same way — the
         * conservative reading is the one that does not delete a payment.
         */
        guard (200...299).contains(response.status),
            let ack = try? JSONDecoder().decode(
                WebmasterIDStoreKitAcknowledgement.self, from: response.body)
        else {
            backOff(after: item, retryAfter: response.retryAfterSeconds)
            return
        }

        lastPaymentOutcome = ack.outcome
        lastIdentityOutcome = ack.identity
        acknowledged += 1
        notBefore = nil

        /*
         * ⚠ THE DISCARD RULE, AND IT IS NOT "THE PAYMENT IS TERMINAL".
         *
         * Every payment outcome is terminal, so keying on that alone would
         * always delete. A banked payment whose identity is `retryable` still
         * needs its JWS: dropping it strands the purchase unlinked forever,
         * because the evidence required to link it is what was deleted.
         */
        if ack.mayDiscardEvidence {
            queue.remove(clientTransactionIDs: [item.clientTransactionID])
        }
    }

    /// Exponential backoff with full jitter, or the server's own `Retry-After`.
    ///
    /// ⚠ `Retry-After` WINS WHEN THE SERVER SENDS ONE. It is the server saying
    /// how long it needs; a client that ignores it and returns on its own curve
    /// is the reason rate limits exist.
    private func backOff(after item: WebmasterIDStoreKitPending, retryAfter: Double? = nil) {
        let delay: Double
        if let retryAfter, retryAfter > 0 {
            delay = min(retryAfter, WebmasterIDBackoff.cap)
            retryAfterHonoured += 1
        } else {
            delay = WebmasterIDBackoff.delay(
                attempt: item.attempts,
                random: Double(random.opaqueIdentifier(for: .clientEvent).count % 100) / 100
            )
        }
        notBefore = clock.now().addingTimeInterval(delay)
    }

    // ── seams the verification suite needs ───────────────────────────────
    //
    // ⚠ `package`, SO THEY ARE INVISIBLE TO CONSUMERS.
    //
    // A `VerificationResult<Transaction>` cannot be constructed without a real
    // App Store, and this package must be verifiable on a machine that has
    // none. These expose the path AFTER the verified/unverified decision — they
    // do not bypass it, and `submit(_:)` above is still the only way in from
    // outside the package.

    /// The enqueue+flush path a verified result takes.
    @discardableResult
    package func submitForTesting(jws: String) async -> WebmasterIDStoreKitEnqueueOutcome {
        let outcome = enqueue(jws: jws)
        await flushIfPossible()
        return outcome
    }

    /// Flush ignoring the backoff window, so a test can exhaust attempts
    /// without simulating hours of wall clock.
    package func flushIgnoringBackoff() async {
        notBefore = nil
        await flushIfPossible()
    }

    /// How many iterators have been created. Proves `start()` is idempotent in
    /// a way that counting a boolean cannot.
    package func listenerGenerationForTesting() -> Int { listenerGeneration }

    // ── the core is the authority ────────────────────────────────────────

    public func diagnostics() -> WebmasterIDStoreKitDiagnostics {
        WebmasterIDStoreKitDiagnostics(
            isListening: listener != nil,
            pending: queue.deliverable.count,
            abandoned: queue.abandonedCount,
            submitted: submitted,
            acknowledged: acknowledged,
            refusedForCapacity: queue.refusedForCapacity,
            droppedForAge: queue.droppedForAge,
            unverifiedRefused: unverifiedRefused,
            retryAfterHonoured: retryAfterHonoured,
            recoveredFromCorruption: queue.recoveredFromCorruption,
            lastEnqueueOutcome: lastEnqueueOutcome,
            lastPaymentOutcome: lastPaymentOutcome,
            lastIdentityOutcome: lastIdentityOutcome
        )
    }
}

extension WebmasterIDStoreKit: WebmasterIDExtensionObserver {
    /// The core told us consent or identity changed. Act, do not ask.
    ///
    /// ⚠ AWAITED BY THE CORE BEFORE ITS MUTATOR RETURNS, so
    /// `await analytics.setConsent(.disabled)` means the evidence is already
    /// gone when it returns — not that it will be, shortly.
    /* `package`, not `public`: the context type is package-internal, so a public
     * conformance would leak it into the SDK's supported surface. */
    package func webmasterIDStateDidChange(_ next: WebmasterIDExtensionContext) async {
        let previous = context
        context = next

        /*
         * ⚠ WITHDRAWAL DELETES, AND CANCELS DELIVERY IN FLIGHT.
         *
         * Keeping signed purchase evidence after the user says stop would be
         * storing exactly what they withdrew permission for. The purchase itself
         * is unaffected: the host app owns `finish()`, and Apple's records are
         * Apple's.
         */
        if next.consent == .decided(.disabled) {
            listener?.cancel()
            listener = nil
            queue.clear()
            return
        }

        /*
         * ⚠ AN EPOCH CHANGE UNLABELS, IT DOES NOT DISCARD.
         *
         * A sign-out or account switch must not relabel a previous user's
         * purchase, and must not throw the payment away either. The claim is
         * dropped from the stored record; delivery still happens, unlabelled.
         *
         * Delivery would refuse the stale epoch anyway — the core resolves it to
         * nil. Clearing it here as well means the stale epoch is not sitting in
         * a file waiting for an epoch counter to wrap round to it.
         */
        if next.identityEpoch != previous.identityEpoch || !next.permitsPersistentIdentifiers {
            queue.clearIdentityClaims()
        }
    }
}

/// Everything an integrator can see, and nothing identifying.
///
/// ⚠ COUNTS AND CLOSED ENUMS ONLY. No Apple transaction identifiers, no JWS, no
/// account key, no Apple error text — a diagnostics struct is exactly the thing
/// that ends up pasted into a support ticket.
public struct WebmasterIDStoreKitDiagnostics: Sendable, Equatable {
    public let isListening: Bool
    public let pending: Int
    /// Items that exhausted their attempts. Retained as evidence, never retried.
    public let abandoned: Int
    public let submitted: Int
    public let acknowledged: Int
    public let refusedForCapacity: Int
    public let droppedForAge: Int
    /// StoreKit could not vouch for these locally, so they were never sent.
    public let unverifiedRefused: Int
    public let retryAfterHonoured: Int
    public let recoveredFromCorruption: Bool
    public let lastEnqueueOutcome: WebmasterIDStoreKitEnqueueOutcome?
    public let lastPaymentOutcome: WebmasterIDStoreKitPaymentOutcome?
    public let lastIdentityOutcome: WebmasterIDStoreKitIdentityOutcome?
}
