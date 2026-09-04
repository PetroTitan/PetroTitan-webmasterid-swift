import Foundation

/// The durable, bounded, FIFO event queue.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// PERSIST BEFORE THE FIRST ATTEMPT, NOT AFTER IT
/// ═══════════════════════════════════════════════════════════════════════════
///
/// An event is written to disk before any delivery is tried. That ordering is
/// the whole point: an app that is killed while a request is in flight has
/// already recorded the event, so the next launch retries it under the SAME
/// `client_event_id` and the server's unique index collapses the duplicate. An
/// event persisted AFTER a failed attempt would not exist to retry.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// EVERY BOUND IS EXPLICIT, BECAUSE AN UNBOUNDED QUEUE IS A DISK-FILL BUG
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Count, encoded bytes and age. A device that is offline for a week must not
/// grow this file without limit, and the oldest events are the ones worth
/// losing — so eviction is from the FRONT, and every drop is counted so the
/// loss is visible in diagnostics rather than silent.
struct WebmasterIDEventQueue: Sendable {
    static let fileName = "queue.v1.json"

    private(set) var events: [WebmasterIDQueuedEvent] = []
    private(set) var droppedForCapacity = 0
    private(set) var droppedForAge = 0
    private(set) var droppedOversized = 0
    private(set) var recoveredFromCorruption = false

    private let storage: any WebmasterIDStorage
    private let maxEvents: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval

    init(storage: any WebmasterIDStorage, maxEvents: Int, maxBytes: Int, maxAge: TimeInterval) {
        self.storage = storage
        self.maxEvents = maxEvents
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

    // ── persistence ──────────────────────────────────────────────────────

    /// Load the queue, surviving anything the file might contain.
    ///
    /// ⚠ CORRUPTION MUST NEVER CRASH THE HOST APP. A truncated write, a disk
    /// error, or a file from a future SDK version all produce the same
    /// outcome: the queue starts empty, the fact is recorded for diagnostics,
    /// and the app keeps running. `try!` or a force-unwrap here would turn a
    /// bad byte in an analytics file into a crash in someone's product.
    mutating func load(now: Date) {
        guard let data = try? storage.read(Self.fileName) else { return }
        guard let decoded = try? Self.decoder.decode([WebmasterIDQueuedEvent].self, from: data) else {
            recoveredFromCorruption = true
            try? storage.remove(Self.fileName)
            events = []
            return
        }
        events = decoded
        pruneExpired(now: now)
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(events) else { return }
        try? storage.write(data, to: Self.fileName)
    }

    // ── mutation ─────────────────────────────────────────────────────────

    mutating func append(_ event: WebmasterIDQueuedEvent, now: Date) {
        events.append(event)
        pruneExpired(now: now)
        enforceBounds()
        persist()
    }

    /// Remove events the server has settled — accepted OR deduplicated.
    ///
    /// A duplicate acknowledgement is a SUCCESS: the server already holds that
    /// event, so keeping it queued would re-send it for ever.
    mutating func removeSettled(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        events.removeAll { ids.contains($0.clientEventID) }
        persist()
    }

    mutating func removeOversized(id: String) {
        events.removeAll { $0.clientEventID == id }
        droppedOversized += 1
        persist()
    }

    /// Consent went to `disabled`: nothing queued may survive.
    mutating func clear() {
        events = []
        try? storage.remove(Self.fileName)
    }

    private mutating func pruneExpired(now: Date) {
        /*
         * The predicate reads `maxAge`, which is a property of the same value
         * `removeAll` is mutating — an exclusivity violation the compiler
         * rejects outright. Copying the bound to a local is not a workaround
         * for a false positive: it removes a genuine simultaneous access.
         */
        let limit = maxAge
        let before = events.count
        events.removeAll { now.timeIntervalSince($0.occurredAt) > limit }
        droppedForAge += before - events.count
    }

    private mutating func enforceBounds() {
        if events.count > maxEvents {
            let excess = events.count - maxEvents
            events.removeFirst(excess)
            droppedForCapacity += excess
        }
        /*
         * Bytes are measured on the ENCODED form, because that is what occupies
         * the disk. A character count would under-measure any non-ASCII value
         * by up to 4×.
         */
        while encodedByteCount > maxBytes, !events.isEmpty {
            events.removeFirst()
            droppedForCapacity += 1
        }
    }

    var encodedByteCount: Int {
        (try? Self.encoder.encode(events))?.count ?? 0
    }
}
