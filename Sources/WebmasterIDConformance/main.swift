import Foundation
import WebmasterID
import WebmasterIDStoreKit

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
    let transport = GateTransport()
    let client = WebmasterIDClient(configuration: try TestSupport.configuration(transport: transport))
    try await client.track(.appOpen)
    let task = Task { await client.flush() }
    /*
     * ⚠ WAIT TO BE TOLD, DO NOT SLEEP AND HOPE.
     *
     * This slept 20 ms against a 120 ms request. On a loaded runner the flush
     * finished first, the queue emptied legitimately, and the check reported a
     * loss that had not happened — which is how 1.0.0's tag run went red on a
     * commit whose main run was green.
     */
    await transport.waitUntilInFlight()
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
    /*
     * ⚠ A THROWING GROUP, BECAUSE `try?` WAS HIDING TWO PROBLEMS.
     *
     * The compiler saw one: `track` is `@discardableResult` and returns
     * `Bool`, so `try?` produced an unused `Bool?` and Swift 6 warned about
     * it. That warning is what stopped CI before it ever reached the iOS
     * build, so the whole platform claim was blocked by this line.
     *
     * The test had the worse problem. `try?` DISCARDS a thrown validation
     * error, so a `track` that refused all fifty events would have left this
     * check asserting "50 delivered" against a client that had rejected every
     * one — and the failure would have read as a delivery bug rather than what
     * it was. A throwing group propagates the error out of `waitForAll`, so an
     * unexpected refusal fails here, by name, at the point it happened.
     *
     * `waitForAll` also makes the wait explicit: every child task — the fifty
     * tracks and the five flushes — completes before the assertions run.
     */
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask { try await client.track(.appOpen) }
        }
        for _ in 0..<5 {
            group.addTask { await client.flush() }
        }
        try await group.waitForAll()
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

// ═══════════════════════════════════════════════════════════════════════════
// STOREKIT — THE TRUST BOUNDARY, THE QUEUE, AND THE ONE AUTHORITY
// ═══════════════════════════════════════════════════════════════════════════

/// A verified/unverified pair cannot be minted without an App Store, so the
/// enqueue path is exercised through the package-visible seam the SDK uses.
func skPair(
    storage: FakeStoreKitStorage = FakeStoreKitStorage(),
    transport: FakeStoreKitTransport = FakeStoreKitTransport(),
    identityStore: any WebmasterIDIdentityStore = WebmasterIDMemoryIdentityStore(),
    clock: FakeClock = FakeClock(),
    maxPending: Int = 128,
    maxBytes: Int = 512 * 1024,
    maxAge: TimeInterval = 30 * 24 * 60 * 60,
    maxAttempts: Int = 12
) async throws -> (WebmasterIDClient, WebmasterIDStoreKit, FakeStoreKitStorage, FakeStoreKitTransport) {
    let analytics = try StoreKitTestSupport.analytics(
        identityStore: identityStore, clock: clock
    )
    let sk = try await StoreKitTestSupport.collector(
        analytics: analytics, storage: storage, transport: transport, clock: clock,
        maxPending: maxPending, maxBytes: maxBytes, maxAge: maxAge, maxAttempts: maxAttempts
    )
    return (analytics, sk, storage, transport)
}

do {
    let transport = FakeStoreKitTransport()
    transport.enqueue(payment: "accepted", identity: "linked")
    let (analytics, sk, _, t) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    try await analytics.identify(externalUserID: "acct-42")
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("a"))

    let body = t.object(0)
    await check("SK1. the envelope declares contract v2", body["contract_version"] as? Int == 2, "\(body)")
    await check("SK2. it carries the JWS verbatim",
                body["signed_transaction"] as? String == StoreKitTestSupport.jws("a"))
    await check("SK3. the identity claim is nested, resolved at DELIVERY from the core",
                (body["identity"] as? [String: Any])?["external_user_id"] as? String == "acct-42",
                "\(body)")

    let keys = Set(body.keys)
    await check("*** SK4. the envelope carries EXACTLY the six contract keys ***",
                keys == ["contract_version", "app_property_id", "signed_transaction",
                         "client_transaction_id", "consent", "identity"], "\(keys.sorted())")
    let identityKeys = Set((body["identity"] as? [String: Any])?.keys ?? [:].keys)
    await check("SK4b. identity carries ONLY the user claim — no client copy of Apple's token",
                identityKeys == ["external_user_id"], "\(identityKeys.sorted())")
    if ProcessInfo.processInfo.environment["WEBMASTERID_DUMP_ENVELOPE"] == "1" {
        print("ENVELOPE " + String(decoding: t.bodies[0], as: UTF8.self))
    }
    await check("SK4c. the emitted envelope matches the shared cross-repo fixture",
                NSDictionary(dictionary: body).isEqual(to: fixtureObject("storekit.submission.v2")),
                String(decoding: t.bodies[0], as: UTF8.self))
    let d = await sk.diagnostics()
    await check("SK5. accepted + linked retires the evidence", d.pending == 0)
}

// ── Phase 3: the raw account key never touches disk ───────────────────────
do {
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, storage, _) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    try await analytics.identify(externalUserID: "acct-USER-A")
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("b"))

    let raw = storage.raw("storekit-evidence.v1.json")
    await check("*** SK28. the queue file contains NO raw external user id ***",
                !raw.contains("acct-USER-A") && !raw.contains("external_user_id")
                    && !raw.contains("externalUserID"), raw)
    await check("SK29. it stores an identity EPOCH instead",
                raw.contains("identityEpoch"), raw)
}

do {
    /*
     * ⚠ THE ACCOUNT-SWITCH TEST. User A buys; User B signs in before delivery
     * succeeds. The request must name NEITHER.
     */
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, storage, t) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    try await analytics.identify(externalUserID: "acct-USER-A")
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("c"))
    let dPre = await sk.diagnostics()
    await check("SK30pre. the purchase is queued and undelivered", dPre.pending == 1)

    try await analytics.identify(externalUserID: "acct-USER-B")
    transport.enqueue(payment: "accepted", identity: "not_provided")
    /*
     * ⚠ `flushIgnoringBackoff`, AND THE FIRST VERSION OF THIS TEST WAS WRONG
     * WITHOUT IT.
     *
     * The 503 above set a backoff window, so a plain `flush()` returned without
     * sending and `bodies.last` was still the FIRST attempt — which legitimately
     * named User A, because User A was current when it was made. The test read
     * that as the SDK leaking a user across an account switch. It was reading
     * the wrong request.
     */
    await sk.flushIgnoringBackoff()

    let sent = String(decoding: t.bodies.last ?? Data(), as: UTF8.self)
    await check("*** SK30. after an account switch the request names NEITHER user ***",
                !sent.contains("acct-USER-A") && !sent.contains("acct-USER-B"), sent)
    await check("SK31. …and the PAYMENT was still delivered",
                sent.contains(StoreKitTestSupport.jws("c")), sent)
    await check("SK32. the stored file never held either user",
                !storage.raw("storekit-evidence.v1.json").contains("acct-USER"))
    let d = await sk.diagnostics()
    await check("SK33. diagnostics name no user",
                "\(d)".contains("acct-USER-A") == false && "\(d)".contains("acct-USER-B") == false)
}

// ── Phase 4: one consent and identity authority ──────────────────────────
do {
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, storage, _) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("d"))
    let d34 = await sk.diagnostics()
    await check("SK34pre. evidence is queued", d34.pending == 1)

    /* A DIRECT core call, not a wrapper. */
    await analytics.setConsent(.disabled)
    let d = await sk.diagnostics()
    await check("*** SK34. a DIRECT core setConsent(.disabled) deletes StoreKit evidence ***",
                d.pending == 0 && !storage.names.contains("storekit-evidence.v1.json"),
                "pending=\(d.pending) files=\(storage.names)")
    await check("SK35. …and cancels the listener", !d.isListening)
}

do {
    let (analytics, sk, storage, transport) = try await skPair()
    /* notDetermined by default. */
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("e"))
    let d = await sk.diagnostics()
    await check("*** SK36. with consent undetermined nothing is queued, stored or sent ***",
                d.pending == 0 && transport.count == 0 && storage.names.isEmpty,
                "files=\(storage.names) sent=\(transport.count)")
    await check("SK37. the refusal is reported to the host",
                d.lastEnqueueOutcome == .refusedByConsent, "\(String(describing: d.lastEnqueueOutcome))")
    _ = analytics
}

do {
    let transport = FakeStoreKitTransport()
    transport.enqueue(payment: "accepted", identity: "not_permitted")
    let (analytics, sk, _, t) = try await skPair(transport: transport)
    await analytics.setConsent(.restricted)
    try? await analytics.identify(externalUserID: "acct-42")
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("f"))
    let raw = String(decoding: t.bodies.first ?? Data(), as: UTF8.self)
    await check("*** SK38. `restricted` sends the purchase and NO user ***",
                t.count == 1 && !raw.contains("identity") && !raw.contains("acct-42"), raw)
    _ = sk
}

do {
    /* Reset unlabels without discarding. */
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, storage, t) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    try await analytics.identify(externalUserID: "acct-42")
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("g"))
    await analytics.resetIdentity()
    let d39 = await sk.diagnostics()
    await check("*** SK39. reset keeps the payment evidence ***", d39.pending == 1)
    await check("SK40. …and strips the queued identity claim",
                !storage.raw("storekit-evidence.v1.json").contains("\"identityEpoch\":1"),
                storage.raw("storekit-evidence.v1.json"))
    transport.enqueue(payment: "accepted", identity: "not_provided")
    await sk.flushIgnoringBackoff()  /* see SK30 — a backoff window hides the retry */
    await check("SK41. the delivered request has no user",
                !String(decoding: t.bodies.last ?? Data(), as: UTF8.self).contains("identity"))
}

// ── Phase 7: the queue's three bounds and its retry behaviour ────────────
do {
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, storage, _) = try await skPair(transport: transport, maxPending: 1)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("h"))
    transport.enqueueRaw(status: 503, body: "{}")
    let second = await sk.submitForTesting(jws: StoreKitTestSupport.jws("i"))
    let d42 = await sk.diagnostics()
    await check("*** SK42. a full queue REFUSES and says so — it evicts nothing ***",
                second == .refusedQueueFull && d42.pending == 1, "\(second)")
    await check("SK43. the first payment is still there",
                storage.raw("storekit-evidence.v1.json").contains(StoreKitTestSupport.jws("h")))
}

do {
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, _, _) = try await skPair(transport: transport, maxBytes: 400)
    await analytics.setConsent(.analyticsAllowed)
    let outcome = await sk.submitForTesting(jws: String(repeating: "z", count: 900))
    await check("*** SK44. the BYTE bound refuses too — a count alone bounds nothing ***",
                outcome == .refusedQueueFull, "\(outcome)")
}

do {
    let clock = FakeClock()
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, _, _) = try await skPair(
        transport: transport, clock: clock, maxAge: 60)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("j"))
    let d45 = await sk.diagnostics()
    await check("SK45pre. queued", d45.pending == 1)
    clock.advance(120)
    await sk.flush()
    let d = await sk.diagnostics()
    await check("*** SK45. the AGE bound is measured from the stored timestamp ***",
                d.pending == 0 && d.droppedForAge == 1,
                "pending=\(d.pending) aged=\(d.droppedForAge)")
}

do {
    /* Attempt ceiling produces an explicit terminal disposition. */
    let transport = FakeStoreKitTransport()
    let (analytics, sk, _, _) = try await skPair(transport: transport, maxAttempts: 2)
    await analytics.setConsent(.analyticsAllowed)
    let clock = FakeClock()
    _ = clock
    for _ in 0..<4 { transport.enqueueRaw(status: 503, body: "{}") }
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("k"))
    for _ in 0..<4 { await sk.flushIgnoringBackoff() }
    let d = await sk.diagnostics()
    await check("*** SK46. an exhausted item becomes ABANDONED, not an immortal skipped row ***",
                d.abandoned == 1 && d.pending == 0, "abandoned=\(d.abandoned) pending=\(d.pending)")
}

do {
    /* Retry-After is honoured. */
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 429, body: "{}", retryAfter: 90)
    let clock = FakeClock()
    let (analytics, sk, _, _) = try await skPair(transport: transport, clock: clock)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("l"))
    let d1 = await sk.diagnostics()
    await check("*** SK47. a 429 keeps the evidence and honours Retry-After ***",
                d1.pending == 1 && d1.retryAfterHonoured == 1,
                "pending=\(d1.pending) retryAfter=\(d1.retryAfterHonoured)")
    let before = transport.count
    await sk.flush()
    await check("SK48. …and the next flush does not fire early",
                transport.count == before, "sent \(transport.count - before) early")
    clock.advance(120)
    transport.enqueue(payment: "accepted", identity: "not_provided")
    await sk.flush()
    let d49 = await sk.diagnostics()
    await check("SK49. …but does fire once the window passes", d49.pending == 0)
}

do {
    /* An unknown status is retained conservatively. */
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 418, body: "{}")
    let (analytics, sk, _, _) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("m"))
    let d50 = await sk.diagnostics()
    await check("*** SK50. an unrecognised status RETAINS — the conservative reading ***",
                d50.pending == 1)
}

do {
    /* Terminal outcomes drain. */
    for (payment, label) in [("rejected", "SK51"), ("duplicate", "SK52")] {
        let transport = FakeStoreKitTransport()
        transport.enqueue(payment: payment, identity: "not_provided")
        let (analytics, sk, _, _) = try await skPair(transport: transport)
        await analytics.setConsent(.analyticsAllowed)
        await sk.submitForTesting(jws: StoreKitTestSupport.jws(payment))
        let dt = await sk.diagnostics()
        await check("\(label). `\(payment)` is terminal — the queue drains", dt.pending == 0)
    }
}

do {
    /* Identity retryable retains a BANKED payment. */
    let transport = FakeStoreKitTransport()
    transport.enqueue(payment: "accepted", identity: "retryable")
    let (analytics, sk, _, _) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    try await analytics.identify(externalUserID: "acct-42")
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("n"))
    let d53 = await sk.diagnostics()
    await check("*** SK53. a banked payment with retryable identity KEEPS its evidence ***",
                d53.pending == 1)
    transport.enqueue(payment: "duplicate", identity: "linked")
    await sk.flush()
    let d = await sk.diagnostics()
    await check("SK54. …and the retry deduplicates the payment and links the identity",
                d.pending == 0 && d.lastIdentityOutcome == .linked)
}

do {
    /* Durability, dedup and corruption. */
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, storage, _) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("o"))
    await check("SK55. evidence is persisted BEFORE any delivery is attempted",
                storage.names.contains("storekit-evidence.v1.json"), "\(storage.names)")
    transport.enqueueRaw(status: 503, body: "{}")
    let again = await sk.submitForTesting(jws: StoreKitTestSupport.jws("o"))
    let d56 = await sk.diagnostics()
    await check("*** SK56. the same signature does not queue twice ***",
                again == .alreadyQueued && d56.pending == 1, "\(again)")

    let reloadedAnalytics = try StoreKitTestSupport.analytics()
    await reloadedAnalytics.setConsent(.analyticsAllowed)
    let reloaded = try await StoreKitTestSupport.collector(
        analytics: reloadedAnalytics, storage: storage, transport: transport)
    let d57 = await reloaded.diagnostics()
    await check("SK57. …and it survives a relaunch", d57.pending == 1)

    storage.corrupt("storekit-evidence.v1.json")
    let afterCorruption = try await StoreKitTestSupport.collector(
        analytics: reloadedAnalytics, storage: storage, transport: transport)
    let dc = await afterCorruption.diagnostics()
    await check("SK58. a corrupt evidence file never crashes the host app",
                dc.recoveredFromCorruption && dc.pending == 0)
}

do {
    /* One listener, and its lifetime. */
    let (analytics, sk, _, _) = try await skPair()
    await analytics.setConsent(.analyticsAllowed)
    for _ in 0..<5 { await sk.start() }
    let g1 = await sk.listenerGenerationForTesting()
    await check("*** SK59. five start() calls create exactly one iterator ***",
                g1 == 1, "generations=\(g1)")
    await sk.stop()
    await sk.start()
    let g2 = await sk.listenerGenerationForTesting()
    await check("SK60. start → stop → start creates ONE new iterator, not two", g2 == 2)
    await sk.stop()
    let d61 = await sk.diagnostics()
    await check("SK61. stop() releases the listener", !d61.isListening)
}

do {
    /* Cancellation preserves evidence. */
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let (analytics, sk, _, _) = try await skPair(transport: transport)
    await analytics.setConsent(.analyticsAllowed)
    await sk.submitForTesting(jws: StoreKitTestSupport.jws("p"))
    await sk.start()
    await sk.stop()
    let d62 = await sk.diagnostics()
    await check("*** SK62. cancelling the observer preserves queued evidence ***",
                d62.pending == 1)
}



// ═══════════════════════════════════════════════════════════════════════════
// STOREKIT — WHAT THE SOURCES MUST NOT CONTAIN
// ═══════════════════════════════════════════════════════════════════════════

do {
    /*
     * ⚠ SOURCE-LEVEL ASSERTIONS, BECAUSE SOME GUARANTEES HAVE NO RUNTIME.
     *
     * "This SDK never finishes your transaction" cannot be proved by calling
     * it — the absence of a call is not observable from outside. It is proved
     * by reading the sources, with comments stripped first, because a comment
     * that SAYS `finish()` is a mention and not a call. That distinction has
     * bitten this project before.
     */
    func code(_ directory: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(directory)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return "" }
        var out = ""
        for file in files where file.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            else { continue }
            var inBlock = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var l = String(line)
                if inBlock {
                    if let end = l.range(of: "*/") { l = String(l[end.upperBound...]); inBlock = false }
                    else { continue }
                }
                if let start = l.range(of: "/*") { l = String(l[..<start.lowerBound]); inBlock = true }
                if let line = l.range(of: "//") { l = String(l[..<line.lowerBound]) }
                out += l + "\n"
            }
        }
        return out
    }

    let storeKitCode = code("WebmasterIDStoreKit")
    let coreCode = code("WebmasterID")

    await check("SK23. the StoreKit sources were actually read",
                storeKitCode.contains("public actor WebmasterIDStoreKit"))

    await check("*** SK24. finish() is NEVER called — finishing is the host app's decision ***",
                !storeKitCode.contains(".finish()") && !storeKitCode.contains("finish("),
                "a call to finish() appeared in the StoreKit sources")

    await check("*** SK25. the CORE target still imports no StoreKit ***",
                !coreCode.contains("import StoreKit"),
                "the core is no longer StoreKit-free")

    /*
     * ⚠ THIS CHECK WAS REVERSED, DELIBERATELY AND ON THE OWNER'S INSTRUCTION.
     *
     * It used to assert the SDK never branches on `VerificationResult`, on the
     * reasoning that a stale device trust store should not lose revenue. The
     * accepted M6.2 contract says the opposite: `.verified` is enqueued,
     * `.unverified` is not sent at all.
     *
     * Recorded as a reversal rather than quietly rewritten, because the old
     * assertion was not a bug — it encoded a different decision. Server-side
     * verification against Apple's roots remains mandatory for everything that
     * IS sent; the local check narrows what is sent, it never decides what is
     * trusted.
     */
    await check("*** SK26. the client enqueues ONLY `.verified`, per the M6.2 contract ***",
                storeKitCode.contains("guard case .verified = result"),
                "the verified-only guard is missing from the submission path")
    await check("SK26b. …and Apple's error text is never retained or logged",
                !storeKitCode.contains("localizedDescription")
                    && !storeKitCode.contains("VerificationResult.VerificationError"),
                "an Apple verification error is being kept")

    // ── Phase 10: the privacy manifest, audited against the code ─────────
    func manifest(_ target: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(target)
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    let skManifest = manifest("WebmasterIDStoreKit")
    let coreManifest = manifest("WebmasterID")

    await check("SK63. the StoreKit target ships its OWN privacy manifest",
                skManifest.contains("<plist"), "no manifest found")

    await check("*** SK64. it declares Purchase History — this module sends purchase evidence ***",
                skManifest.contains("NSPrivacyCollectedDataTypePurchaseHistory"))

    await check("SK65. …and User ID, because the envelope can carry the account key",
                skManifest.contains("NSPrivacyCollectedDataTypeUserID"))

    await check("*** SK66. the CORE does NOT declare Purchase History ***",
                !coreManifest.contains("NSPrivacyCollectedDataTypePurchaseHistory"),
                "an analytics-only consumer would over-declare")

    await check("SK67. the StoreKit module declares no Device ID — its envelope carries none",
                !skManifest.contains("NSPrivacyCollectedDataTypeDeviceID"))

    await check("SK68. …and no Coarse Location — its route retains no country",
                !skManifest.contains("NSPrivacyCollectedDataTypeCoarseLocation"))

    await check("SK69. tracking is false and there are no tracking domains, in both",
                skManifest.contains("<key>NSPrivacyTracking</key>\n  <false/>")
                    && skManifest.contains("<key>NSPrivacyTrackingDomains</key>\n  <array/>"))

    /*
     * ⚠ REQUIRED-REASON APIs, CHECKED AGAINST THE SOURCES RATHER THAN ASSERTED
     * IN A COMMENT.
     *
     * The age bound is the one that could have needed a reason code: reading
     * the file's modification date is category C617.1. It is measured from a
     * timestamp inside the record instead, so the declaration stays empty and
     * this proves it rather than promising it.
     */
    let requiredReasonAPIs = [
        "modificationDate", "creationDate", "getattrlist", "fstat", "stat(",
        "UserDefaults", "systemUptime", "mach_absolute_time",
        "volumeAvailableCapacity", "statfs", "activeInputModes",
    ]
    let usedRequiredReason = requiredReasonAPIs.filter { storeKitCode.contains($0) }
    await check("*** SK70. no required-reason API is used, so the empty declaration is honest ***",
                usedRequiredReason.isEmpty, "found: \(usedRequiredReason)")

    await check("SK71. the age bound reads the record's own timestamp, not the file's",
                storeKitCode.contains("timeIntervalSince($0.queuedAt)"),
                "the age bound is not measured from queuedAt")

    await check("SK27. no underscored SPI — sharing is `package`, which the compiler enforces",
                !storeKitCode.contains("@_spi") && !coreCode.contains("@_spi"))
}

let (passed, failures) = await results.summary()
print("\n  \(passed)/\(passed + failures.count) guarantees held")
if !failures.isEmpty {
    print("  FAILURES:")
    failures.forEach { print("    - \($0)") }
    exit(1)
}
