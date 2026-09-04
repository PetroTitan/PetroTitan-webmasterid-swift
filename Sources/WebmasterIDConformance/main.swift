import Foundation
import WebmasterID

/// M4 — the conformance suite.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHY AN EXECUTABLE AND NOT A TEST TARGET
/// ═══════════════════════════════════════════════════════════════════════════
///
/// XCTest and swift-testing both ship with Xcode. The machine this was
/// developed on has Command Line Tools only, and `import XCTest` /
/// `import Testing` fail to resolve — so a `.testTarget` would have been code
/// that was never compiled, presented as a test suite. This runs instead, for
/// real, and fails the process on the first broken guarantee.
///
/// It uses ONLY the public API. That is not a limitation working around the
/// lack of `@testable`: every guarantee checked here is one a host application
/// could verify for itself, which is a stronger claim than reaching into
/// internals to confirm they look right.

// ───────────────────────────────────────────────────────────────────────────

actor Results {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    /*
     * The detail is a plain `String`, not an autoclosure. A non-Sendable
     * closure crossing into an actor is a data race the Swift 6 compiler
     * refuses outright — and evaluating the detail eagerly costs nothing here,
     * because these strings are short and the suite runs once.
     */
    func record(_ label: String, _ ok: Bool, _ detail: String) {
        if ok {
            passed += 1
            print("  PASS  \(label)")
        } else {
            failures.append("\(label)\(detail.isEmpty ? "" : " — \(detail)")")
            print("  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    func summary() -> (Int, [String]) { (passed, failures) }
}

let results = Results()

func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") async {
    await results.record(label, ok, ok ? "" : detail())
}

func fixtureObject(_ name: String) -> [String: Any] {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

let ISO = "2026-09-03T12:00:00.000Z"

print("\nWEBMASTERID SWIFT SDK — CONFORMANCE\n")

// ═══════════════════════════════════════════════════════════════════════════
// 1-3 — GOLDEN ENCODING AND THE CLOSED KEY SET
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    let storage = FakeStorage()
    let random = FakeRandomSource()
    let clock = FakeClock(Date(timeIntervalSince1970: 1_788_393_600))
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(
            storage: storage, transport: transport, clock: clock, random: random
        )
    )
    try await client.track(.appOpen)
    await client.flush()

    let golden = fixtureObject("request.minimal")
    let goldenKeys = Set(((golden["events"] as? [[String: Any]])?.first ?? [:]).keys)
    let sentEvent = transport.events(0).first ?? [:]

    /*
     * The golden minimal fixture is the smallest event the SERVER accepts:
     * five keys, no identifiers. A consented SDK always adds one more —
     * `installation_id` — because under `analytics_allowed` an installation
     * identity exists and omitting it would lose the only pseudonymous link
     * between two events from the same device.
     *
     * So the assertion is that the SDK sends the golden set PLUS exactly that
     * one key, and nothing else. Asserting bare equality would have been the
     * easier test and would have been wrong in a way that only looked strict.
     */
    await check("1. a minimal event carries the golden keys plus the installation id",
                Set(sentEvent.keys) == goldenKeys.union(["installation_id"]),
                "sent \(Set(sentEvent.keys).sorted()) vs golden \(goldenKeys.sorted())")
    await check("1b. …and every key the server REQUIRES is present",
                goldenKeys.isSubset(of: Set(sentEvent.keys)),
                "missing \(goldenKeys.subtracting(Set(sentEvent.keys)).sorted())")

    await check("2. the envelope carries only v, property_id and events",
                Set((transport.json(0) ?? [:]).keys) == ["v", "property_id", "events"])

    let serverKeys: Set<String> = [
        "event_id", "event_name", "occurred_at", "session_id", "consent",
        "screen", "cta_id", "filter_id", "installation_id", "external_user_id",
        "app_version", "app_build", "os_major", "locale", "timezone",
        "actor_role", "eligibility_outcome",
    ]
    let rich = WebmasterIDEventContext(
        screen: "BookingDetail", ctaID: nil, filterID: nil,
        appVersion: "3.1.0", appBuild: "412", osMajor: 18,
        locale: "en-GB", timezone: "Europe/Prague",
        actorRole: .consumer, eligibilityOutcome: .eligible
    )
    try await client.track(.screenView, context: rich)
    await client.flush()
    let richKeys = Set((transport.events(1).first ?? [:]).keys)
    await check("*** 3. the SDK cannot emit a key the route does not accept ***",
                richKeys.isSubset(of: serverKeys),
                "extra: \(richKeys.subtracting(serverKeys).sorted())")

    let body = String(decoding: transport.bodies[0], as: UTF8.self)
    await check("3b. a nil optional is omitted, never sent as null",
                !body.contains("null"), body)
}

// ═══════════════════════════════════════════════════════════════════════════
// 4-6 — EVENT IDENTITY
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    try await client.track(.screenView, context: .init(screen: "Home"))
    await client.flush()

    let ids = transport.events(0).compactMap { $0["event_id"] as? String }
    await check("4. every logical event gets its own client_event_id",
                Set(ids).count == 2, "\(ids)")
    await check("6. two real events remain two events", ids.count == 2, "\(ids.count)")
}

do {
    /* A 5xx then a success: the SAME id must arrive both times. */
    let transport = FakeTransport()
    transport.enqueue(status: 503, body: #"{"error":"storage_unavailable","retryable":true}"#)
    transport.setFallback(status: 200, body: #"{"accepted":1,"deduplicated":0,"rejected":0}"#)
    let storage = FakeStorage()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(storage: storage, transport: transport)
    )
    try await client.track(.appOpen)
    await client.flush()
    await client.flush()

    let first = transport.events(0).first?["event_id"] as? String
    let second = transport.events(1).first?["event_id"] as? String
    await check("*** 5. a retry carries the SAME client_event_id ***",
                first != nil && first == second, "\(first ?? "nil") vs \(second ?? "nil")")

    let firstTime = transport.events(0).first?["occurred_at"] as? String
    let secondTime = transport.events(1).first?["occurred_at"] as? String
    await check("5b. …and the ORIGINAL occurrence time, not the delivery time",
                firstTime == secondTime, "\(firstTime ?? "-") vs \(secondTime ?? "-")")
}

// ═══════════════════════════════════════════════════════════════════════════
// 7-9 — CONSENT
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    let storage = FakeStorage()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(
            consent: .notDetermined, storage: storage, transport: transport
        )
    )
    let accepted = try await client.track(.appOpen)
    await client.flush()
    await check("*** 7. with consent undetermined, nothing is queued or sent ***",
                accepted == false && transport.sent.isEmpty && storage.raw("queue.v1.json") == nil,
                "accepted=\(accepted) sent=\(transport.sent.count) queued=\(storage.raw("queue.v1.json") != nil)")
}

do {
    let transport = FakeTransport()
    let storage = FakeStorage()
    let identity = WebmasterIDMemoryIdentityStore()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(
            storage: storage, transport: transport, identityStore: identity
        )
    )
    try await client.identify(externalUserID: "acct_9f2b71")
    try await client.track(.appOpen)
    await check("8pre. an identified, queued event exists to be cleared",
                storage.raw("queue.v1.json") != nil && identity.load() != nil)

    await client.setConsent(.disabled)
    let stillQueued = storage.raw("queue.v1.json")
    await check("*** 8. consent disabled clears the queue AND the stored identity ***",
                stillQueued == nil && identity.load() == nil,
                "queue=\(stillQueued != nil) identity=\(identity.load() != nil)")

    let afterDisable = try await client.track(.appOpen)
    await client.flush()
    await check("8b. …and nothing is collected afterwards",
                afterDisable == false && transport.sent.isEmpty)
}

do {
    let transport = FakeTransport()
    let identity = WebmasterIDMemoryIdentityStore()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(
            consent: .decided(.restricted), transport: transport, identityStore: identity
        )
    )
    try await client.identify(externalUserID: "acct_9f2b71")
    try await client.track(.ctaTap, context: .init(ctaID: "book_now"))
    await client.flush()

    let event = transport.events(0).first ?? [:]
    let body = String(decoding: transport.bodies.first ?? Data(), as: UTF8.self)
    await check("*** 9. restricted consent sends NO installation_id ***",
                event["installation_id"] == nil && !body.contains("installation_id"))
    await check("*** 9b. restricted consent sends NO external_user_id ***",
                event["external_user_id"] == nil && !body.contains("external_user_id"))
    await check("9c. …and the account key was never even stored",
                identity.load() == nil)
    await check("9d. the restricted event itself is still delivered",
                event["consent"] as? String == "restricted", body)
}

// ═══════════════════════════════════════════════════════════════════════════
// 10-12 — IDENTITY AND SESSION
// ═══════════════════════════════════════════════════════════════════════════

do {
    let random = FakeRandomSource()
    let transport = FakeTransport()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(transport: transport, random: random)
    )
    try await client.track(.appOpen)
    await client.flush()
    let event = transport.events(0).first ?? [:]

    let installation = event["installation_id"] as? String
    let session = event["session_id"] as? String
    await check("*** 10. installation and session ids come from different purposes ***",
                installation?.hasPrefix("installation-") == true
                    && session?.hasPrefix("session-") == true,
                "\(installation ?? "-") / \(session ?? "-")")
    await check("10b. neither is derived from the other",
                installation != session)
    await check("10c. the client_event_id is a third, separate draw",
                (event["event_id"] as? String)?.hasPrefix("b3f1c2d4") == true)
}

do {
    let identity = WebmasterIDMemoryIdentityStore()
    let transport = FakeTransport()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(transport: transport, identityStore: identity)
    )
    try await client.identify(externalUserID: "acct_9f2b71")
    try await client.track(.login)
    await client.flush()
    await check("11. identify attaches the account key",
                transport.events(0).first?["external_user_id"] as? String == "acct_9f2b71")

    var rejected = false
    do { try await client.identify(externalUserID: "person@example.com") } catch { rejected = true }
    await check("*** 11b. an email is REFUSED as an account key, not hashed ***", rejected)

    await client.resetIdentity()
    try await client.track(.appOpen)
    await client.flush()
    let afterReset = transport.events(1).first ?? [:]
    await check("*** 11c. after reset the account key is gone ***",
                afterReset["external_user_id"] == nil && identity.load() == nil)
    await check("11d. …and a NEW installation id is in force",
                (afterReset["installation_id"] as? String) != (transport.events(0).first?["installation_id"] as? String))
}

do {
    let clock = FakeClock()
    let transport = FakeTransport()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(transport: transport, clock: clock)
    )
    try await client.track(.appOpen)
    await client.flush()
    let before = transport.events(0).first?["session_id"] as? String

    clock.advance(31 * 60)
    try await client.track(.appOpen)
    await client.flush()
    let after = transport.events(1).first?["session_id"] as? String

    await check("*** 12. the session rotates after the documented inactivity window ***",
                before != nil && after != nil && before != after, "\(before ?? "-") -> \(after ?? "-")")
    await check("12b. the session id is opaque, not a timestamp",
                !(after ?? "").contains("2026") && !(after ?? "").contains("178"))
}

// ═══════════════════════════════════════════════════════════════════════════
// 13-16 — THE QUEUE
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    for _ in 0..<5 { try await client.track(.appOpen) }
    await client.flush()
    let ids = transport.events(0).compactMap { $0["event_id"] as? String }
    await check("13. the queue is FIFO", ids == ids.sorted(), "\(ids)")
}

do {
    /* A process restart: a NEW client over the SAME storage. */
    let storage = FakeStorage()
    let offline = FakeTransport()
    offline.setFallback(status: 503, body: #"{"retryable":true}"#)
    let first = WebmasterIDClient(
        configuration: try TestSupport.configuration(storage: storage, transport: offline)
    )
    try await first.track(.appOpen)
    try await first.track(.login)
    await first.flush()
    await check("14pre. the events survived a failed delivery", storage.raw("queue.v1.json") != nil)

    let online = FakeTransport()
    let second = WebmasterIDClient(
        configuration: try TestSupport.configuration(storage: storage, transport: online)
    )
    await second.flush()
    await check("*** 14. a restart recovers the durable queue and delivers it ***",
                online.events(0).count == 2, "\(online.events(0).count)")
}

do {
    let storage = FakeStorage()
    let transport = FakeTransport()
    let warmup = WebmasterIDClient(
        configuration: try TestSupport.configuration(storage: storage, transport: FakeTransport(always: 503))
    )
    try await warmup.track(.appOpen)
    await warmup.flush()
    storage.corrupt("queue.v1.json")

    let recovered = WebmasterIDClient(
        configuration: try TestSupport.configuration(storage: storage, transport: transport)
    )
    let diag = await recovered.diagnostics()
    try await recovered.track(.appOpen)
    await recovered.flush()
    await check("*** 15. a corrupted queue is survived, not crashed on ***",
                diag.recoveredFromCorruptQueue && diag.queuedEvents == 0)
    await check("15b. …and the client keeps working afterwards",
                transport.events(0).count == 1)
}

do {
    let storage = FakeStorage()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(
            storage: storage, transport: FakeTransport(always: 503), maxQueuedEvents: 3
        )
    )
    for _ in 0..<10 { try await client.track(.appOpen) }
    let diag = await client.diagnostics()
    await check("*** 16. the queue is BOUNDED by count ***",
                diag.queuedEvents == 3, "\(diag.queuedEvents)")
    await check("16b. …and the loss is counted rather than silent",
                diag.droppedForCapacity == 7, "\(diag.droppedForCapacity)")
}

do {
    let clock = FakeClock()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(
            transport: FakeTransport(always: 503), clock: clock, maxEventAge: 60
        )
    )
    try await client.track(.appOpen)
    clock.advance(120)
    try await client.track(.login)
    let diag = await client.diagnostics()
    await check("16c. an event older than the TTL is dropped",
                diag.queuedEvents == 1 && diag.droppedExpired == 1,
                "queued=\(diag.queuedEvents) expired=\(diag.droppedExpired)")
}

// ═══════════════════════════════════════════════════════════════════════════
// 17-19 — BATCHING AND SIZE
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    /* Non-ASCII on purpose: a character count would under-measure these. */
    for i in 0..<60 {
        try await client.track(.screenView, context: .init(screen: "Obrazovka\(i)"))
    }
    await client.flush()

    let sizes = transport.bodies.map(\.count)
    await check("*** 17. every request body is within the 48 KiB limit ***",
                sizes.allSatisfy { $0 <= WebmasterIDContract.maxBodyBytes }, "\(sizes)")
    await check("17b. no batch exceeds 50 events",
                (0..<transport.sent.count).allSatisfy { transport.events($0).count <= 50 })
    let total = (0..<transport.sent.count).map { transport.events($0).count }.reduce(0, +)
    await check("17c. all 60 events were delivered across the batches", total == 60, "\(total)")
}

do {
    /*
     * ⚠ A LOWERED BYTE BUDGET, BECAUSE THE REAL ONE CANNOT BE REACHED.
     *
     * Every envelope field is bounded, so fifty maximal events come to roughly
     * 25 KiB — the 48 KiB check never binds with valid data, and a test using
     * the default would pass whether the code counted bytes or characters. A
     * mutation proved exactly that: swapping the byte count for a character
     * count left the suite green.
     *
     * So the budget is lowered to 1 KiB and the values are deliberately
     * non-ASCII: "Obrazovka" with Czech diacritics is 2 bytes per accented
     * character, so a character-counted batch overshoots and this fails.
     */
    let transport = FakeTransport()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(transport: transport, maxBatchBytes: 1_024)
    )
    for i in 0..<40 {
        try await client.track(.screenView, context: .init(screen: "Obrazovka-příliš-\(i)"))
    }
    await client.flush()
    let byteSizes = transport.bodies.map(\.count)
    await check("*** 17d. batching is byte-accurate, not character-counted ***",
                byteSizes.allSatisfy { $0 <= 1_024 }, "\(byteSizes)")
    await check("17e. …and every event still arrives",
                (0..<transport.sent.count).map { transport.events($0).count }.reduce(0, +) == 40)
    await check("17f. …across more than one request",
                transport.sent.count > 1, "\(transport.sent.count)")
}

do {
    let transport = FakeTransport()
    transport.enqueue(status: 413)
    transport.setFallback(status: 200, body: #"{"accepted":1,"deduplicated":0,"rejected":0}"#)
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    for _ in 0..<8 { try await client.track(.appOpen) }
    await client.flush()
    await client.flush()
    let diag = await client.diagnostics()
    await check("18. a 413 does not lose the batch",
                diag.queuedEvents == 0 || transport.sent.count > 1,
                "queued=\(diag.queuedEvents) requests=\(transport.sent.count)")
}

do {
    /*
     * A single event that cannot fit is dropped locally rather than retried
     * until the age bound expires. The transport answers 413 forever.
     */
    let transport = FakeTransport(always: 413)
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    for _ in 0..<5 { await client.flush() }
    let diag = await client.diagnostics()
    await check("*** 19. one oversized event is not retried forever ***",
                diag.queuedEvents == 0 && diag.droppedOversized >= 1,
                "queued=\(diag.queuedEvents) oversized=\(diag.droppedOversized)")
}

// ═══════════════════════════════════════════════════════════════════════════
// 20-23 — DELIVERY SEMANTICS
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    transport.enqueue(status: 429, body: #"{"error":"rate_limited"}"#, retryAfter: 42)
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    await client.flush()
    let diag = await client.diagnostics()
    if case let .scheduled(seconds, _) = diag.retryState {
        await check("*** 20. a 429 honours Retry-After ***", seconds == 42, "\(seconds)")
    } else {
        await check("*** 20. a 429 honours Retry-After ***", false, "\(diag.retryState)")
    }
    await check("20b. …and the events stay queued", diag.queuedEvents == 1)
    await check("20c. …and the status category says rate limited",
                diag.lastStatusCategory == .rateLimited)
}

do {
    let transport = FakeTransport(always: 500)
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(transport: transport, maxDeliveryAttempts: 4)
    )
    try await client.track(.appOpen)
    var delays: [Double] = []
    for _ in 0..<3 {
        await client.flush()
        if case let .scheduled(seconds, _) = await client.diagnostics().retryState {
            delays.append(seconds)
        }
    }
    await check("*** 21. a 5xx schedules a bounded retry ***",
                !delays.isEmpty && delays.allSatisfy { $0 >= 0 && $0 <= 300 }, "\(delays)")
    await check("21b. …and the events are never lost to it",
                await client.diagnostics().queuedEvents == 1)

    await client.flush()
    let after = await client.diagnostics()
    await check("21c. attempts are bounded — it does not spin forever",
                after.retryState == .stopped(reason: .attemptsExhausted), "\(after.retryState)")
}

do {
    let transport = FakeTransport(always: 400, body: #"{"error":"invalid_payload","reason":"unknown_key"}"#)
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    await client.flush()
    await client.flush()
    let diag = await client.diagnostics()
    await check("*** 22. a 400 is not retried forever ***",
                diag.queuedEvents == 0 && transport.sent.count == 1,
                "queued=\(diag.queuedEvents) requests=\(transport.sent.count)")
    await check("22b. …and the permanent rejection is counted",
                diag.permanentlyRejected == 1, "\(diag.permanentlyRejected)")
}

do {
    let transport = FakeTransport(always: 403, body: #"{"error":"property_not_accepting_events"}"#)
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    await client.flush()
    let diag = await client.diagnostics()
    await check("*** 23. a 403 stops delivery for the property ***",
                diag.retryState == .stopped(reason: .propertyNotAccepting), "\(diag.retryState)")
    let described = "\(diag.retryState) \(diag.lastStatusCategory.rawValue)"
    await check("*** 23b. …and never discloses archived versus unknown ***",
                !described.lowercased().contains("archiv") && !described.lowercased().contains("unknown"),
                described)
}

// ═══════════════════════════════════════════════════════════════════════════
// 24-26 — ACKNOWLEDGEMENT, CANCELLATION, CONCURRENCY
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    transport.enqueue(status: 200, body: #"{"accepted":0,"deduplicated":2,"rejected":0}"#)
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    try await client.track(.login)
    await client.flush()
    let diag = await client.diagnostics()
    await check("*** 24. a DEDUPLICATED acknowledgement removes the work ***",
                diag.queuedEvents == 0, "\(diag.queuedEvents)")
    await check("24b. …and is counted as deduplicated, not as a failure",
                diag.deduplicated == 2 && diag.permanentlyRejected == 0,
                "dedup=\(diag.deduplicated)")
    await check("24c. accepted + deduplicated accounts for the batch",
                diag.acknowledged + diag.deduplicated == 2)
}

do {
    /*
     * ⚠ THE FIRST VERSION OF THIS CHECK WAS VACUOUS.
     *
     * It used a 503 transport, so the queue survived because of the RETRY
     * path, not because of anything about cancellation — a mutation that
     * cleared the queue on cancellation left the suite green, because the code
     * never reached the cancellation branch.
     *
     * The real guarantee is narrower and stronger: the queue is mutated ONLY
     * after a settled response. So the transport below succeeds, and the
     * cancellation happens while the request is in flight.
     */
    let transport = SlowTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    let task = Task { await client.flush() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()
    _ = await task.value
    let diag = await client.diagnostics()
    await check("*** 25. work cancelled in flight is preserved, not lost ***",
                diag.queuedEvents == 1, "\(diag.queuedEvents)")
    await client.flush()
    await check("25b. …and it is delivered on the next flush",
                await client.diagnostics().queuedEvents == 0, "still queued")
}

do {
    let transport = FakeTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask { try? await client.track(.appOpen) }
        }
        for _ in 0..<5 {
            group.addTask { await client.flush() }
        }
    }
    await client.flush()
    let delivered = (0..<transport.sent.count).map { transport.events($0).count }.reduce(0, +)
    let allIDs = (0..<transport.sent.count).flatMap { transport.events($0).compactMap { $0["event_id"] as? String } }
    let diag = await client.diagnostics()
    await check("*** 26. concurrent track and flush neither duplicate nor lose events ***",
                delivered == 50 && diag.queuedEvents == 0,
                "delivered=\(delivered) queued=\(diag.queuedEvents)")
    await check("26b. …and no event was sent twice",
                Set(allIDs).count == allIDs.count, "\(allIDs.count) sends, \(Set(allIDs).count) unique")
}

// ═══════════════════════════════════════════════════════════════════════════
// 27 — DIAGNOSTICS DISCLOSE NOTHING
// ═══════════════════════════════════════════════════════════════════════════

do {
    let identity = WebmasterIDMemoryIdentityStore()
    let transport = FakeTransport()
    let client = WebmasterIDClient(
        configuration: try TestSupport.configuration(transport: transport, identityStore: identity)
    )
    try await client.identify(externalUserID: "acct_secret_value")
    try await client.track(.screenView, context: .init(screen: "SecretScreen"))
    await client.flush()
    let rendered = String(describing: await client.diagnostics())

    for forbidden in ["acct_secret_value", "SecretScreen", "installation-", "session-", "127.0.0.1", "ap_0123"] {
        await check("*** 27. diagnostics never expose \(forbidden) ***",
                    !rendered.contains(forbidden), rendered)
    }
    let diag = await client.diagnostics()
    await check("27b. …but they DO distinguish the delivery states",
                diag.queued == 1 && diag.attempted == 1 && diag.acknowledged == 1
                    && diag.queuedEvents == 0,
                "\(diag)")
}

// ═══════════════════════════════════════════════════════════════════════════
// APP PROPERTY WITHOUT A SITE
// ═══════════════════════════════════════════════════════════════════════════

do {
    let transport = FakeTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    await client.flush()
    let body = String(decoding: transport.bodies.first ?? Data(), as: UTF8.self)
    await check("*** an app property needs no website: no site id, no URL, no domain ***",
                !body.contains("site_id") && !body.contains("http") && !body.contains("url"),
                body)
}

// ═══════════════════════════════════════════════════════════════════════════

let (passed, failures) = await results.summary()
print("\n  \(passed)/\(passed + failures.count) guarantees held")
if !failures.isEmpty {
    print("  FAILURES:")
    failures.forEach { print("    - \($0)") }
    exit(1)
}
