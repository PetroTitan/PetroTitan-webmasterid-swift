import Foundation

/// One piece of unacknowledged signed evidence, waiting for the server.
struct WebmasterIDStoreKitPending: Sendable, Codable, Equatable {
    /// Apple's compact JWS.
    ///
    /// ⚠ THIS IS THE ONE PLACE THE RAW JWS IS WRITTEN TO DISK, AND IT IS
    /// DELIBERATE. A queue that discarded the signature could not retry, and a
    /// purchase made in a tunnel would be lost. It lives here only until the
    /// server acknowledges it — see `WebmasterIDStoreKitStorage` for the file
    /// protection this file is written under.
    let signedTransaction: String
    /// Minted here, once. Never Apple's identifier.
    let clientTransactionID: String
    let queuedAt: Date
    var attempts: Int
    /// ⚠ AN EPOCH, NEVER THE RAW ACCOUNT KEY.
    ///
    /// The previous version of this struct stored `externalUserID: String?`,
    /// which put the host application's raw user id in a JSON file on disk. It
    /// also encoded the WRONG rule: it captured the user at purchase time and
    /// shipped that label whatever happened afterwards.
    ///
    /// The epoch is an opaque counter owned by the core client. At delivery the
    /// core is asked "is the identity that was current at this epoch STILL
    /// current?" — and answers nil after any sign-out, reset or account switch.
    /// So a purchase made by User A is never delivered labelled as User B, and
    /// it is never labelled as A either once A has gone: it is delivered
    /// UNLABELLED, and the payment is never dropped for it.
    var identityEpoch: Int?
    var consent: String
    /// Set once the item has exhausted its attempts. It stays in the file as
    /// evidence, but it is no longer retried and diagnostics say so.
    var abandoned: Bool = false
}

/// The protected, bounded, FIFO evidence queue.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// A SEPARATE QUEUE FROM THE EVENT QUEUE, NOT A SHARED ONE
/// ═══════════════════════════════════════════════════════════════════════════
///
/// The event queue evicts from the front when it is full and drops anything
/// older than its age bound — correct for analytics, catastrophic for a
/// purchase. Sharing one queue would mean a burst of screen views could push a
/// customer's payment evidence off the end.
///
/// So evidence gets its own file, its own bounds, and an eviction rule that
/// says the opposite thing: when the queue is full the NEWEST submission is
/// refused rather than the oldest evidence discarded, and the refusal is
/// counted. Losing the newest is recoverable — StoreKit will re-offer an
/// unfinished transaction on the next launch, because the host app has not
/// called `finish()`. Losing the oldest is not.
/// The outcome of trying to store evidence — returned to the host, not swallowed.
///
/// ⚠ AN ENQUEUE THAT FAILS MUST BE OBSERVABLE. Silently dropping a payment
/// because a queue was full is the failure mode this type exists to prevent:
/// the host is told WebmasterID did not retain the purchase, and can decide
/// what to do about it. Nothing here identifies anyone.
public enum WebmasterIDStoreKitEnqueueOutcome: String, Sendable, Equatable, CaseIterable {
    /// Stored, and it will be delivered.
    case stored
    /// Already held — the same signature arrived twice. Not an error.
    case alreadyQueued
    /// Consent does not permit collection. Nothing was written.
    case refusedByConsent
    /// The JWS exceeded the field limit. Nothing was written.
    case refusedTooLarge
    /// The queue is at its count or byte bound. ⚠ NOTHING WAS RETAINED.
    case refusedQueueFull
    /// StoreKit could not vouch for the payload locally, so it was not sent.
    case refusedUnverified
    /// Storage itself failed. Nothing was retained.
    case refusedStorageUnavailable
}

/// The protected, bounded, FIFO evidence queue.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// A SEPARATE QUEUE FROM THE EVENT QUEUE, NOT A SHARED ONE
/// ═══════════════════════════════════════════════════════════════════════════
///
/// The event queue evicts from the front when it is full and drops anything
/// older than its age bound — correct for analytics, catastrophic for a
/// purchase. Sharing one queue would let a burst of screen views push a
/// customer's payment evidence off the end.
///
/// So evidence gets its own file, its own bounds, and an eviction rule that
/// says the opposite thing: when the queue is full the new submission is
/// REFUSED and the caller is told, rather than an older payment being silently
/// discarded to make room. Neither the oldest nor the newest payment is dropped
/// on the floor.
///
/// ⚠ AN EARLIER VERSION JUSTIFIED DROPPING THE NEWEST BY SAYING STOREKIT WOULD
/// RE-OFFER IT. That is not guaranteed: the host application may already have
/// called `finish()` by then, and a finished transaction is never re-offered.
/// Durability has to stand on this file alone, which is why the refusal is
/// reported instead of assumed harmless.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// THREE BOUNDS, NOT ONE
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Count alone is not a bound on anything that matters: 128 entries of 16 KiB
/// is 2 MiB of a user's disk. The encoded byte size and an age limit are both
/// enforced, and the age limit reads the timestamp STORED IN THE RECORD rather
/// than the file's mtime — a file rewritten by an unrelated append would
/// otherwise refresh the age of everything in it.
struct WebmasterIDStoreKitQueue: Sendable {
    static let fileName = "storekit-evidence.v1.json"

    private(set) var pending: [WebmasterIDStoreKitPending] = []
    private(set) var refusedForCapacity = 0
    private(set) var droppedForAge = 0
    private(set) var abandonedCount = 0
    private(set) var recoveredFromCorruption = false

    private let storage: any WebmasterIDStoreKitStorage
    private let maxPending: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval

    init(
        storage: any WebmasterIDStoreKitStorage,
        maxPending: Int,
        maxBytes: Int,
        maxAge: TimeInterval
    ) {
        self.storage = storage
        self.maxPending = maxPending
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Items still worth attempting: not abandoned.
    var deliverable: [WebmasterIDStoreKitPending] { pending.filter { !$0.abandoned } }

    /// ⚠ CORRUPTION MUST NEVER CRASH THE HOST APP. A truncated write or a file
    /// from a future SDK version starts the queue empty and records the fact.
    mutating func load(now: Date) {
        guard let data = try? storage.read(Self.fileName) else { return }
        guard let decoded = try? Self.decoder.decode([WebmasterIDStoreKitPending].self, from: data)
        else {
            recoveredFromCorruption = true
            try? storage.remove(Self.fileName)
            pending = []
            return
        }
        pending = decoded
        pruneExpired(now: now)
    }

    /// Drop anything older than the age bound.
    ///
    /// ⚠ MEASURED FROM `queuedAt` IN THE RECORD, NOT FROM THE FILE.
    /// The file is rewritten on every append, so its modification time says when
    /// the queue last changed — not how old the oldest purchase in it is.
    mutating func pruneExpired(now: Date) {
        let before = pending.count
        /* `maxAge` is `self.maxAge`, so reading it inside a closure that mutates
         * `self.pending` is an overlapping access. Copy it out first. */
        let limit = maxAge
        pending.removeAll { now.timeIntervalSince($0.queuedAt) > limit }
        let removed = before - pending.count
        if removed > 0 {
            droppedForAge += removed
            persist()
        }
    }

    private func encodedBytes(_ items: [WebmasterIDStoreKitPending]) -> Int {
        (try? Self.encoder.encode(items))?.count ?? 0
    }

    @discardableResult
    private mutating func persist() -> Bool {
        guard let data = try? Self.encoder.encode(pending) else { return false }
        do {
            try storage.write(data, to: Self.fileName)
            return true
        } catch {
            return false
        }
    }

    /// Enqueue, ALWAYS persisting before any delivery is attempted.
    mutating func append(
        _ item: WebmasterIDStoreKitPending,
        now: Date
    ) -> WebmasterIDStoreKitEnqueueOutcome {
        pruneExpired(now: now)

        /*
         * ⚠ DEDUPLICATED ON THE SIGNATURE ITSELF.
         *
         * `Transaction.updates` re-delivers an unfinished transaction on every
         * launch, and the host may also submit the same purchase explicitly.
         * Both arrive with the SAME JWS. Without this the queue would grow one
         * entry per launch, each with a different `clientTransactionID`, so one
         * payment would reach the server as many distinct submissions.
         */
        if pending.contains(where: { $0.signedTransaction == item.signedTransaction }) {
            return .alreadyQueued
        }
        guard pending.count < maxPending else {
            refusedForCapacity += 1
            return .refusedQueueFull
        }
        /* The byte bound is checked against what the file WOULD become. */
        /* Copied to a local first: `pending + [item]` while `pending` is being
         * mutated is an overlapping access the compiler rejects. */
        let projected = pending + [item]
        guard encodedBytes(projected) <= maxBytes else {
            refusedForCapacity += 1
            return .refusedQueueFull
        }
        pending.append(item)
        guard persist() else {
            /* Storage refused. Do not pretend it is retained. */
            pending.removeLast()
            return .refusedStorageUnavailable
        }
        return .stored
    }

    /// Retire acknowledged evidence.
    mutating func remove(clientTransactionIDs: Set<String>) {
        guard !clientTransactionIDs.isEmpty else { return }
        pending.removeAll { clientTransactionIDs.contains($0.clientTransactionID) }
        persist()
    }

    /// Record an attempt, and abandon the item if it has run out.
    ///
    /// ⚠ ABANDONED IS AN EXPLICIT STATE, NOT AN IMMORTAL SKIPPED ROW.
    ///
    /// The previous version compared `attempts < maxDeliveryAttempts` at flush
    /// time and simply skipped anything above it — so an item that ran out sat
    /// in the file forever, never sent, never removed, and invisible in
    /// diagnostics. It is now marked, counted, and no longer retried.
    mutating func recordAttempt(clientTransactionID: String, ceiling: Int) {
        guard let index = pending.firstIndex(where: { $0.clientTransactionID == clientTransactionID })
        else { return }
        pending[index].attempts += 1
        if pending[index].attempts >= ceiling, !pending[index].abandoned {
            pending[index].abandoned = true
            abandonedCount += 1
        }
        persist()
    }

    /// Forget queued identity labels without discarding the payments.
    ///
    /// Used when the core client's identity epoch moves — a sign-out or an
    /// account switch. The evidence stays; only the claim about WHO goes.
    mutating func clearIdentityClaims() {
        var changed = false
        for index in pending.indices where pending[index].identityEpoch != nil {
            pending[index].identityEpoch = nil
            changed = true
        }
        if changed { persist() }
    }

    mutating func clear() {
        pending = []
        try? storage.remove(Self.fileName)
    }
}
