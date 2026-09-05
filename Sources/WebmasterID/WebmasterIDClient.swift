import Foundation

/// The WebmasterID analytics client.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// AN ACTOR, AND NOT A SINGLETON
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Everything mutable — the queue, the identity record, the counters, the
/// retry state — lives inside this actor, so concurrent `track` calls from any
/// thread cannot interleave into a corrupted queue. There is no shared
/// instance: an app creates one, a test creates several, and two clients in
/// one process never share a file because the storage is scoped by property.
///
/// Nothing here touches the main actor, and nothing blocks. `track` is `async`
/// and returns as soon as the event is durable.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHAT M4 IS, AND WHAT IT IS NOT
/// ═══════════════════════════════════════════════════════════════════════════
///
/// It sends ANALYTICS EVENTS. It does not report verified conversions, revenue,
/// purchases, subscriptions or refunds; StoreKit and trusted purchase
/// reporting are later phases, and the server would refuse those fields today.
/// There is no IDFA, no AppTrackingTransparency, no Location Services, no
/// device fingerprinting and no UI swizzling — not disabled, absent.
public actor WebmasterIDClient {
    /// The one registered package extension, held WEAKLY — see ExtensionBridge.
    weak var extensionObserver: (any WebmasterIDExtensionObserver)?

    private var configuration: WebmasterIDConfiguration
    private var queue: WebmasterIDEventQueue
    private var identity: WebmasterIDLocalIdentity
    private var consentState: WebmasterIDConsentState

    // ── counters, all bounded and content-free ───────────────────────────
    private var queuedCount = 0
    private var attemptedCount = 0
    private var acknowledgedCount = 0
    private var deduplicatedCount = 0
    private var rejectedCount = 0
    private var lastSuccessAt: Date?
    private var lastStatus: WebmasterIDDiagnostics.StatusCategory = .none
    private var retryState: WebmasterIDDiagnostics.RetryState = .idle
    private var consecutiveFailures = 0
    private var stopped: WebmasterIDDiagnostics.StoppedReason?
    private var isShutDown = false
    /*
     * ⚠ SINGLE-FLIGHT DELIVERY, AND THE REASON IS ACTOR REENTRANCY.
     *
     * An actor serialises access, but it does NOT hold the lock across an
     * `await`. `deliverOneBatch` suspends on the network, and while it is
     * suspended another `flush()` enters, reads the SAME queue — the batch has
     * not been acknowledged yet, so nothing was removed — and sends it again.
     *
     * Measured, not theorised: five concurrent flushes over fifty events
     * produced 250 requests, each event sent five times. The server would have
     * collapsed them (that is what `client_event_id` is for), so no data was
     * wrong; the client simply did five times the work and five times the
     * radio wake-ups. This flag makes a second caller return immediately, and
     * the loop already running drains whatever it queued.
     */
    private var isDelivering = false

    private static let identityFile = "identity.v1.json"

    public init(configuration: WebmasterIDConfiguration) {
        self.configuration = configuration
        self.consentState = configuration.consent
        self.queue = WebmasterIDEventQueue(
            storage: configuration.storage,
            maxEvents: configuration.maxQueuedEvents,
            maxBytes: configuration.maxQueuedBytes,
            maxAge: configuration.maxEventAge
        )

        let now = configuration.clock.now()
        /*
         * The local identity is loaded, not created, when a record exists —
         * otherwise every launch would mint a new installation id and the
         * "installation" would mean "process".
         */
        if let data = try? configuration.storage.read(Self.identityFile),
           let stored = try? JSONDecoder().decode(WebmasterIDLocalIdentity.self, from: data) {
            identity = stored
        } else {
            identity = WebmasterIDLocalIdentity(
                installationID: nil,
                sessionID: configuration.random.opaqueIdentifier(for: .session),
                sessionLastActiveAt: now,
                identityEpoch: 0
            )
        }
        queue.load(now: now)

        if let supplied = configuration.externalUserID,
           let validated = try? WebmasterIDUserIDValidator.validate(supplied),
           consentState.permitsPersistentIdentifiers {
            identity.identityEpoch += 1
            configuration.identityStore.save(
                WebmasterIDStoredIdentity(externalUserID: validated, epoch: identity.identityEpoch)
            )
        }
        /*
         * ⚠ THE SIDE EFFECTS RUN AS FREE FUNCTIONS, NOT AS METHODS.
         *
         * An actor's initializer is a nonisolated context in Swift 6, so it
         * cannot call an isolated method. Rather than making the whole init
         * async — which would stop an app constructing the client in a
         * property initialiser — the two pieces of work that must happen at
         * construction are written as static functions over the state they
         * touch. They are the same code the isolated methods call.
         */
        Self.applyConsent(consentState, identity: &identity, queue: &queue, store: configuration.identityStore)
        Self.persist(identity, to: configuration.storage)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PUBLIC SURFACE
    // ═══════════════════════════════════════════════════════════════════════

    /// Record one logical event.
    ///
    /// It is assigned exactly one `client_event_id` here and keeps it across
    /// every retry, batch split, background transition and process restart. A
    /// retry is therefore never a new logical event, and the server's unique
    /// index collapses a duplicate delivery into an acknowledgement.
    @discardableResult
    public func track(
        _ name: WebmasterIDEventName,
        context: WebmasterIDEventContext = WebmasterIDEventContext()
    ) throws -> Bool {
        guard !isShutDown else { return false }
        /*
         * ⚠ CONSENT IS CHECKED BEFORE THE QUEUE, NOT BEFORE THE NETWORK.
         *
         * Checking only at send time would mean an event captured without
         * permission was still written to disk — collection has already
         * happened at that point, and "we never uploaded it" is not the same
         * statement as "we never collected it".
         */
        guard let wireConsent = consentState.wire, wireConsent.permitsCollection else { return false }

        try validate(name: name, context: context)

        let now = configuration.clock.now()
        rotateSessionIfNeeded(now: now)

        let event = WebmasterIDQueuedEvent(
            clientEventID: configuration.random.uuidV4(),
            name: name,
            occurredAt: now,
            sessionID: identity.sessionID,
            consent: wireConsent,
            installationID: wireConsent.permitsPersistentIdentifiers ? currentInstallationID(now: now) : nil,
            identityEpoch: wireConsent.permitsPersistentIdentifiers ? identity.identityEpoch : nil,
            context: context
        )
        queue.append(event, now: now)
        queuedCount += 1
        return true
    }

    /// Change the consent state, applying every consequence immediately.
    public func setConsent(_ consent: WebmasterIDConsent) async {
        consentState = .decided(consent)
        applyConsentSideEffects(now: configuration.clock.now())
        persistIdentity()
        /*
         * ⚠ AWAITED BEFORE RETURNING. `.disabled` must mean every package
         * extension has already dropped what it was holding — not that it will,
         * shortly, on some other task.
         */
        await notifyExtensionObserver()
    }

    /// Attach an application-supplied account key.
    ///
    /// Throws for an empty value, an over-long one, or anything containing `@`
    /// or whitespace — an email address is a direct identifier this product
    /// must never receive, and hashing it silently would hide the mistake from
    /// the developer who made it.
    public func identify(externalUserID: String) async throws {
        let validated = try WebmasterIDUserIDValidator.validate(externalUserID)
        guard consentState.permitsPersistentIdentifiers else { return }
        identity.identityEpoch += 1
        configuration.identityStore.save(
            WebmasterIDStoredIdentity(externalUserID: validated, epoch: identity.identityEpoch)
        )
        persistIdentity()
        await notifyExtensionObserver()
    }

    /// Log out: forget the account key and start a new pseudonymous identity.
    ///
    /// The epoch advances, so events queued while the previous user was signed
    /// in resolve to no user id at send time. That loses an attribution the
    /// developer might have wanted, and it is the correct trade: the person has
    /// said they are done, and shipping their account key afterwards is not.
    public func resetIdentity() async {
        configuration.identityStore.clear()
        identity.identityEpoch += 1
        identity.installationID = consentState.permitsPersistentIdentifiers
            ? configuration.random.opaqueIdentifier(for: .installation)
            : nil
        identity.sessionID = configuration.random.opaqueIdentifier(for: .session)
        identity.sessionLastActiveAt = configuration.clock.now()
        persistIdentity()
        await notifyExtensionObserver()
    }

    /// Deliver everything queued, one batch at a time, until nothing is left
    /// or the server says stop.
    @discardableResult
    public func flush() async -> Bool {
        guard !isShutDown, stopped == nil else { return false }
        /*
         * A concurrent caller does not wait and does not duplicate: the loop
         * below runs `while !queue.events.isEmpty`, so anything queued in the
         * meantime is picked up by the delivery already in progress.
         */
        guard !isDelivering else { return false }
        isDelivering = true
        defer { isDelivering = false }
        var madeProgress = false
        while !queue.events.isEmpty {
            let outcome = await deliverOneBatch()
            switch outcome {
            case .progressed: madeProgress = true
            case .halted: return madeProgress
            }
            if Task.isCancelled {
                /*
                 * ⚠ CANCELLATION PRESERVES UNACKNOWLEDGED WORK. The queue is
                 * only ever mutated after a settled response, so a cancelled
                 * flush leaves every un-acknowledged event exactly where it was.
                 */
                return madeProgress
            }
        }
        return madeProgress
    }

    /// The app moved to the foreground. Rotates the session if it has expired.
    public func applicationDidBecomeActive() {
        rotateSessionIfNeeded(now: configuration.clock.now(), force: true)
        persistIdentity()
    }

    /// The app is going to the background. Flushes what it can.
    ///
    /// ⚠ THIS DOES NOT PROMISE DELIVERY AFTER TERMINATION. iOS gives a
    /// backgrounding app a short, unguaranteed window; a `URLSession` request
    /// started here may simply not finish. Anything undelivered stays on disk
    /// and is retried on the next launch, which is the actual guarantee. A
    /// background `URLSessionConfiguration` would change that, and it is not
    /// implemented — so it is not claimed.
    public func applicationDidEnterBackground() async {
        await flush()
    }

    /// Stop accepting events and flush what is already queued.
    public func shutdown() async {
        await flush()
        isShutDown = true
    }

    public func diagnostics() -> WebmasterIDDiagnostics {
        WebmasterIDDiagnostics(
            configured: .configured,
            consent: consentState.wire,
            queuedEvents: queue.events.count,
            queuedBytes: queue.encodedByteCount,
            lastSuccessfulDeliveryAt: lastSuccessAt,
            lastStatusCategory: lastStatus,
            retryState: stopped.map { .stopped(reason: $0) } ?? retryState,
            queued: queuedCount,
            attempted: attemptedCount,
            acknowledged: acknowledgedCount,
            deduplicated: deduplicatedCount,
            permanentlyRejected: rejectedCount,
            droppedOversized: queue.droppedOversized,
            droppedExpired: queue.droppedForAge,
            droppedForCapacity: queue.droppedForCapacity,
            recoveredFromCorruptQueue: queue.recoveredFromCorruption
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNALS
    // ═══════════════════════════════════════════════════════════════════════

    private enum BatchResult { case progressed, halted }

    private func deliverOneBatch() async -> BatchResult {
        let userID = configuration.identityStore.load()
        guard let plan = WebmasterIDBatcher.plan(
            from: queue.events,
            propertyID: configuration.appPropertyID,
            resolveUserID: { epoch in
                guard let epoch, let userID, userID.epoch == epoch else { return nil }
                return userID.externalUserID
            },
            limitBytes: configuration.maxBatchBytes
        ) else { return .halted }

        /* A single event that cannot fit is dropped locally, not retried. */
        if plan.body.count > configuration.maxBatchBytes, plan.events.count == 1 {
            queue.removeOversized(id: plan.events[0].clientEventID)
            return .progressed
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = plan.body

        attemptedCount += 1
        let response: WebmasterIDHTTPResponse
        do {
            response = try await configuration.transport.send(request)
        } catch {
            lastStatus = .transportError
            return scheduleRetry()
        }

        switch WebmasterIDDeliveryClassifier.classify(response) {
        case let .settled(ack):
            lastStatus = .success
            lastSuccessAt = configuration.clock.now()
            consecutiveFailures = 0
            retryState = .idle
            acknowledgedCount += ack.accepted
            deduplicatedCount += ack.deduplicated
            /*
             * The response reports COUNTS, not which events. It cannot say
             * more, because the route answers per batch — so the batch we sent
             * is the batch that settled, and the whole of it is removed. This
             * SDK does not invent per-event knowledge the response never gave.
             */
            queue.removeSettled(ids: Set(plan.events.map(\.clientEventID)))
            return .progressed

        case .permanentlyInvalid:
            /*
             * 400 is about the CONTENT. Re-sending the identical bytes gets the
             * identical answer for ever, so the batch is dropped and counted —
             * loudly, in diagnostics — rather than looped.
             */
            lastStatus = .clientError
            rejectedCount += plan.events.count
            queue.removeSettled(ids: Set(plan.events.map(\.clientEventID)))
            return .progressed

        case .propertyRefused:
            /* Archived or unknown — indistinguishable, and stays that way. */
            lastStatus = .refused
            stopped = .propertyNotAccepting
            return .halted

        case .tooLarge:
            let smaller = WebmasterIDBatcher.split(plan.events)
            if smaller.count == plan.events.count, plan.events.count == 1 {
                queue.removeOversized(id: plan.events[0].clientEventID)
                return .progressed
            }
            lastStatus = .clientError
            return .progressed

        case let .rateLimited(retryAfter):
            lastStatus = .rateLimited
            consecutiveFailures += 1
            retryState = .scheduled(inSeconds: retryAfter ?? 60, attempt: consecutiveFailures)
            return .halted

        case .retryable:
            lastStatus = .serverError
            return scheduleRetry()
        }
    }

    private func scheduleRetry() -> BatchResult {
        consecutiveFailures += 1
        if consecutiveFailures >= configuration.maxDeliveryAttempts {
            stopped = .attemptsExhausted
            return .halted
        }
        retryState = .scheduled(
            inSeconds: WebmasterIDBackoff.delay(attempt: consecutiveFailures, random: Double.random(in: 0...1)),
            attempt: consecutiveFailures
        )
        return .halted
    }

    private func currentInstallationID(now: Date) -> String? {
        if let existing = identity.installationID { return existing }
        let minted = configuration.random.opaqueIdentifier(for: .installation)
        identity.installationID = minted
        persistIdentity()
        return minted
    }

    private func rotateSessionIfNeeded(now: Date, force: Bool = false) {
        if force || WebmasterIDSessionRule.isExpired(lastActiveAt: identity.sessionLastActiveAt, now: now) {
            if WebmasterIDSessionRule.isExpired(lastActiveAt: identity.sessionLastActiveAt, now: now) {
                identity.sessionID = configuration.random.opaqueIdentifier(for: .session)
            }
        }
        identity.sessionLastActiveAt = now
    }

    private func applyConsentSideEffects(now: Date) {
        _ = now
        Self.applyConsent(consentState, identity: &identity, queue: &queue, store: configuration.identityStore)
    }

    private static func applyConsent(
        _ consentState: WebmasterIDConsentState,
        identity: inout WebmasterIDLocalIdentity,
        queue: inout WebmasterIDEventQueue,
        store: any WebmasterIDIdentityStore
    ) {
        switch consentState {
        case .notDetermined:
            /* Nothing has been permitted, so nothing persistent may exist. */
            identity.installationID = nil
        case let .decided(consent):
            switch consent {
            case .disabled:
                /*
                 * Immediate and total: the queue is emptied, the installation
                 * id is forgotten, and the account key is removed from the
                 * Keychain. "Stop sending" would not be enough — the data is
                 * already collected, and it may not be retained.
                 */
                queue.clear()
                identity.installationID = nil
                store.clear()
            case .restricted:
                /* No stable identifier may be retained under restricted. */
                identity.installationID = nil
                store.clear()
            case .analyticsAllowed:
                break
            }
        }
    }

    private func persistIdentity() {
        Self.persist(identity, to: configuration.storage)
    }

    private static func persist(_ identity: WebmasterIDLocalIdentity, to storage: any WebmasterIDStorage) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        try? storage.write(data, to: Self.identityFile)
    }

    private func validate(name: WebmasterIDEventName, context: WebmasterIDEventContext) throws {
        if let screen = context.screen {
            guard name.permitsScreen else { throw WebmasterIDValidationError.screenNotPermittedForEvent(name) }
            guard Self.isSymbolic(screen, max: WebmasterIDContract.maxScreenLength) else {
                throw WebmasterIDValidationError.invalidScreen
            }
        }
        if let cta = context.ctaID {
            guard name == .ctaTap else { throw WebmasterIDValidationError.controlIdentifierNotPermittedForEvent(name) }
            guard Self.isSymbolic(cta, max: WebmasterIDContract.maxIdentifierLength) else {
                throw WebmasterIDValidationError.invalidControlIdentifier
            }
        }
        if let filter = context.filterID {
            guard name == .filterApplied else { throw WebmasterIDValidationError.controlIdentifierNotPermittedForEvent(name) }
            guard Self.isSymbolic(filter, max: WebmasterIDContract.maxIdentifierLength) else {
                throw WebmasterIDValidationError.invalidControlIdentifier
            }
        }
        for value in [context.appVersion, context.appBuild].compactMap({ $0 }) {
            guard Self.isSymbolic(value, max: WebmasterIDContract.maxAppVersionLength) else {
                throw WebmasterIDValidationError.invalidAppVersion
            }
        }
        if let os = context.osMajor, !(1...99).contains(os) {
            throw WebmasterIDValidationError.invalidOSMajor
        }
        if let locale = context.locale, !Self.isBCP47(locale) {
            throw WebmasterIDValidationError.invalidLocale
        }
        if let tz = context.timezone, tz.isEmpty || tz.count > 64 || tz.hasPrefix("+") || tz.hasPrefix("-") {
            throw WebmasterIDValidationError.invalidTimezone
        }
    }

    /// A symbol a developer typed, never a sentence or a path.
    static func isSymbolic(_ value: String, max: Int) -> Bool {
        guard !value.isEmpty, value.count <= max else { return false }
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isBCP47(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        guard let language = parts.first, (2...3).contains(language.count),
              language.allSatisfy(\.isLetter) else { return false }
        for part in parts.dropFirst() {
            let ok = (part.count == 4 && part.allSatisfy(\.isLetter))
                || (part.count == 2 && part.allSatisfy(\.isLetter))
                || (part.count == 3 && part.allSatisfy(\.isNumber))
            if !ok { return false }
        }
        return true
    }
}

extension WebmasterIDClient {
    /// The current state, for an extension deciding what it may do right now.
    /// The public property identifier, for a package extension addressing the
    /// same property. Not a secret and not authentication — but `package`
    /// anyway, because nothing outside this package has a reason to read it
    /// back off the client.
    package var packageAppPropertyID: String { configuration.appPropertyID }

    package func extensionContext() -> WebmasterIDExtensionContext {
        WebmasterIDExtensionContext(
            consent: consentState,
            identityEpoch: identity.identityEpoch
        )
    }

    /// The account key that was current at `epoch`, or nil.
    ///
    /// ⚠ RETURNS NIL WHENEVER THE EPOCH HAS MOVED, AND THAT IS THE POINT.
    ///
    /// A purchase queued while User A was signed in must never be delivered
    /// labelled as User B. Resolution happens at DELIVERY and is refused unless
    /// the identity is the same one that was current when the item was queued —
    /// so a sign-out, a reset or an account switch silently and permanently
    /// unlabels everything queued before it, without discarding the item.
    ///
    /// It also returns nil when consent no longer permits a persistent
    /// identifier, so a downgrade to `restricted` unlabels queued work too.
    package func resolveExternalUserID(forEpoch epoch: Int?) -> String? {
        guard let epoch else { return nil }
        guard consentState.permitsPersistentIdentifiers else { return nil }
        guard let stored = configuration.identityStore.load() else { return nil }
        guard stored.epoch == epoch else { return nil }
        return stored.externalUserID
    }

    /// Register the one extension that needs to hear about changes.
    ///
    /// The current state is delivered immediately, so an extension never has to
    /// guess what it missed between construction and registration.
    package func registerExtensionObserver(_ observer: any WebmasterIDExtensionObserver) async {
        extensionObserver = observer
        await observer.webmasterIDStateDidChange(extensionContext())
    }

    /// Push the current state to the registered extension, and WAIT for it.
    ///
    /// ⚠ AWAITED, NOT FIRED INTO A DETACHED TASK.
    ///
    /// `setConsent(.disabled)` has to mean the extension's stored evidence is
    /// gone by the time the call returns. A `Task { }` would make that
    /// eventually-true, which is indistinguishable from never-true in a test and
    /// from a data-retention bug in production.
    ///
    /// The mutators became `async` for this. That is source-compatible: every
    /// caller is outside the actor and already writes `await`.
    func notifyExtensionObserver() async {
        guard let observer = extensionObserver else { return }
        await observer.webmasterIDStateDidChange(extensionContext())
    }
}
