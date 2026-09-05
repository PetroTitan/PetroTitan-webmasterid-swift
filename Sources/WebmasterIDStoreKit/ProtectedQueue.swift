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
    /// The identity claim as it stood when the purchase happened.
    ///
    /// Captured at queue time rather than read at send time: if the user signs
    /// out between the purchase and a successful delivery, the purchase still
    /// belongs to whoever made it.
    var externalUserID: String?
    var consent: String
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
struct WebmasterIDStoreKitQueue: Sendable {
    static let fileName = "storekit-evidence.v1.json"

    private(set) var pending: [WebmasterIDStoreKitPending] = []
    private(set) var refusedForCapacity = 0
    private(set) var recoveredFromCorruption = false

    private let storage: any WebmasterIDStoreKitStorage
    private let maxPending: Int

    init(storage: any WebmasterIDStoreKitStorage, maxPending: Int) {
        self.storage = storage
        self.maxPending = maxPending
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

    /// ⚠ CORRUPTION MUST NEVER CRASH THE HOST APP — the same rule the event
    /// queue follows. A truncated write or a file from a future SDK version
    /// starts the queue empty and records the fact.
    ///
    /// Losing evidence here is survivable precisely because `finish()` is the
    /// host app's call: an unfinished transaction is re-offered by StoreKit on
    /// the next launch.
    mutating func load() {
        guard let data = try? storage.read(Self.fileName) else { return }
        guard let decoded = try? Self.decoder.decode([WebmasterIDStoreKitPending].self, from: data)
        else {
            recoveredFromCorruption = true
            try? storage.remove(Self.fileName)
            pending = []
            return
        }
        pending = decoded
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(pending) else { return }
        try? storage.write(data, to: Self.fileName)
    }

    /// Enqueue, ALWAYS persisting before any delivery is attempted.
    ///
    /// Returns false when the queue is full — the caller has not lost the
    /// purchase, because it never called `finish()`.
    @discardableResult
    mutating func append(_ item: WebmasterIDStoreKitPending) -> Bool {
        /*
         * ⚠ DEDUPLICATED ON THE SIGNATURE ITSELF.
         *
         * `Transaction.updates` re-delivers an unfinished transaction on every
         * launch, and the host app may also submit the same purchase result
         * explicitly. Both arrive with the SAME JWS. Without this the queue
         * would grow one entry per launch for a transaction the app never
         * finishes — and every one of them would carry a different
         * `clientTransactionID`, so the server would see them as distinct
         * submissions of one payment.
         *
         * The payment would still deduplicate server-side on Apple's canonical
         * key. The queue would not.
         */
        if pending.contains(where: { $0.signedTransaction == item.signedTransaction }) {
            return true
        }
        guard pending.count < maxPending else {
            refusedForCapacity += 1
            return false
        }
        pending.append(item)
        persist()
        return true
    }

    /// Retire acknowledged evidence.
    mutating func remove(clientTransactionIDs: Set<String>) {
        guard !clientTransactionIDs.isEmpty else { return }
        pending.removeAll { clientTransactionIDs.contains($0.clientTransactionID) }
        persist()
    }

    mutating func recordAttempt(clientTransactionID: String) {
        guard let index = pending.firstIndex(where: { $0.clientTransactionID == clientTransactionID })
        else { return }
        pending[index].attempts += 1
        persist()
    }

    mutating func clear() {
        pending = []
        try? storage.remove(Self.fileName)
    }
}
