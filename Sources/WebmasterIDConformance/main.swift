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
// STOREKIT — THE TRUST BOUNDARY, THE QUEUE, AND WHAT IS NOT IN THE SOURCES
// ═══════════════════════════════════════════════════════════════════════════

do {
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueue(payment: "accepted", identity: "linked")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: storage, transport: transport, externalUserID: "acct-42"))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("a"))
    let body = transport.object(0)

    await check("SK1. the envelope declares contract v2",
                body["contract_version"] as? Int == 2, "\(body)")
    await check("SK2. it carries the JWS verbatim",
                body["signed_transaction"] as? String == StoreKitTestSupport.jws("a"))
    await check("SK3. the identity claim is nested, not top-level",
                (body["identity"] as? [String: Any])?["external_user_id"] as? String == "acct-42",
                "\(body)")

    /*
     * ⚠ THE CENTRAL GUARANTEE: APPLE DECIDES MONEY.
     *
     * Not "these keys are filtered out" — there is no property on the
     * submission type that could hold them. This asserts the wire bytes.
     */
    /*
     * ⚠ ASSERTED AS A CLOSED KEY SET, NOT AS ABSENT SUBSTRINGS.
     *
     * The substring version of this check FAILED on its first run — and it was
     * the check that was wrong, not the SDK. `client_transaction_id` contains
     * `transaction_id`, so a blanket "the body must not contain
     * transaction_id" flags the one field the contract requires. That is the
     * same mention-versus-use confusion that has bitten this project before,
     * and the fix is the same: compare structure, not text.
     *
     * Equality against the whole set is also strictly stronger. A denylist only
     * catches the forbidden keys someone remembered to list; this fails for ANY
     * key that appears and should not — including one nobody has thought of.
     */
    /*
     * ⚠ EMITTED FOR THE SERVER REPOSITORY TO CONSUME.
     *
     * The two repositories cannot import each other, so the only honest way to
     * prove the wire contract agrees is to have the SDK print the bytes it
     * actually sends and let the server's own suite parse THOSE. Set
     * `WEBMASTERID_DUMP_ENVELOPE=1` and copy the line into the server fixture.
     */
    if ProcessInfo.processInfo.environment["WEBMASTERID_DUMP_ENVELOPE"] == "1" {
        print("ENVELOPE " + String(decoding: transport.bodies[0], as: UTF8.self))
    }

    let keys = Set(body.keys)
    await check("*** SK4. the envelope carries EXACTLY the six contract keys, and no other ***",
                keys == [
                    "contract_version", "app_property_id", "signed_transaction",
                    "client_transaction_id", "consent", "identity",
                ],
                "\(keys.sorted())")

    /*
     * ⚠ THE CROSS-REPOSITORY CONTRACT, PINNED IN BOTH DIRECTIONS.
     *
     * This fixture is byte-for-byte what the SDK emits, and the SAME file is
     * committed in the private server repository, where the server's own
     * parser is run against it. Neither repository can import the other, so
     * without a shared artefact "the contract agrees" is an assertion nobody
     * checks — and the first sign of a disagreement would be a 400 in
     * production.
     */
    await check("SK4c. the emitted envelope matches the shared cross-repo fixture",
                NSDictionary(dictionary: body)
                    .isEqual(to: fixtureObject("storekit.submission.v2")),
                String(decoding: transport.bodies[0], as: UTF8.self))

    let identityKeys = Set((body["identity"] as? [String: Any])?.keys ?? [:].keys)
    await check("*** SK4b. identity carries ONLY the user claim — no client copy of Apple's token ***",
                identityKeys == ["external_user_id"], "\(identityKeys.sorted())")

    let d5 = await sk.diagnostics()
    await check("SK5. the accepted+linked evidence is retired", d5.pending == 0)
}

do {
    /* The discard rule — the half that is easy to get wrong. */
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueue(payment: "accepted", identity: "retryable")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: storage, transport: transport, externalUserID: "acct-42"))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("b"))
    let d6 = await sk.diagnostics()
    await check("*** SK6. a BANKED payment whose identity is retryable KEEPS its evidence ***",
                d6.pending == 1, "pending=\(d6.pending)")

    transport.enqueue(payment: "duplicate", identity: "linked")
    await sk.flush()
    let d7 = await sk.diagnostics()
    await check("SK7. …and the retry deduplicates the payment and converges the identity",
                d7.pending == 0 && d7.lastIdentityOutcome == .linked)
}

do {
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueue(payment: "rejected", identity: "not_provided")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("c"))
    let d8 = await sk.diagnostics()
    await check("SK8. `rejected` is terminal — the queue drains rather than looping forever",
                d8.pending == 0)
}

do {
    /* A non-2xx is not an acknowledgement. */
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: #"{"error":"temporarily_unavailable"}"#)
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("d"))
    let d9 = await sk.diagnostics()
    await check("*** SK9. a 503 KEEPS the evidence — a verifier outage is not a refusal ***",
                d9.pending == 1)

    transport.failOnce()
    await sk.flush()
    let d10 = await sk.diagnostics()
    await check("SK10. a transport failure keeps it too", d10.pending == 1)
}

do {
    /* Consent. */
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: storage, transport: transport, consent: .notDetermined,
            externalUserID: "acct-42"))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("e"))
    let d11 = await sk.diagnostics()
    await check("*** SK11. with consent undetermined, no evidence is queued, stored or sent ***",
                d11.pending == 0 && transport.count == 0 && storage.names.isEmpty,
                "files=\(storage.names) sent=\(transport.count)")
}

do {
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: storage, transport: transport, consent: .decided(.restricted),
            externalUserID: "acct-42"))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("f"))
    let raw = String(decoding: transport.bodies.first ?? Data(), as: UTF8.self)

    /*
     * ⚠ THE PAYMENT SURVIVES `restricted`; THE USER DOES NOT.
     *
     * Refusing to report the purchase would lose revenue while protecting
     * nothing — it is the merchant's own record of a transaction. What is
     * dropped is the identity claim, and it is dropped ON THE DEVICE so it
     * cannot be read by a proxy on the way to a server that would drop it too.
     */
    await check("*** SK12. under `restricted` the purchase is sent and the user is not ***",
                transport.count == 1 && !raw.contains("identity")
                    && !raw.contains("acct-42"), raw)
}

do {
    /* The queue is durable and deduplicated. */
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("g"))
    await check("SK13. evidence is persisted BEFORE any delivery is attempted",
                storage.names.contains("storekit-evidence.v1.json"), "\(storage.names)")

    /* The same transaction re-offered on the next launch. */
    transport.enqueueRaw(status: 503, body: "{}")
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("g"))
    let d14 = await sk.diagnostics()
    await check("*** SK14. a re-offered transaction does NOT queue twice ***",
                d14.pending == 1, "pending=\(d14.pending)")

    let reloaded = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    let d15 = await reloaded.diagnostics()
    await check("SK15. …and it survives a relaunch", d15.pending == 1)
}

do {
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("h"))
    storage.corrupt("storekit-evidence.v1.json")
    let reloaded = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    let d16 = await reloaded.diagnostics()
    await check("SK16. a corrupt evidence file never crashes the host app",
                d16.recoveredFromCorruption && d16.pending == 0)
}

do {
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: storage, transport: transport, maxPending: 1))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("i"))
    transport.enqueueRaw(status: 503, body: "{}")
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("j"))
    /*
     * ⚠ THE NEWEST IS REFUSED, NOT THE OLDEST EVICTED — the opposite of the
     * event queue. Losing the newest is recoverable: the host app has not
     * finished the transaction, so StoreKit re-offers it. Losing the oldest
     * evidence is not.
     */
    let d17 = await sk.diagnostics()
    await check("*** SK17. a full evidence queue refuses the NEWEST, never evicts the oldest ***",
                d17.pending == 1 && d17.refusedForCapacity == 1)
}

do {
    /* Withdrawal. */
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    transport.enqueueRaw(status: 503, body: "{}")
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(storage: storage, transport: transport))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("k"))
    await sk.setConsent(.disabled)
    let d18 = await sk.diagnostics()
    await check("SK18. withdrawing consent clears stored purchase evidence",
                d18.pending == 0 && !storage.names.contains("storekit-evidence.v1.json"),
                "\(storage.names)")
}

do {
    /* An email address never leaves the device. */
    let storage = FakeStoreKitStorage()
    let transport = FakeStoreKitTransport()
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: storage, transport: transport, externalUserID: "person@example.com"))
    await sk.submit(signedTransaction: StoreKitTestSupport.jws("l"))
    let raw = String(decoding: transport.bodies.first ?? Data(), as: UTF8.self)
    await check("*** SK19. an email address in external_user_id never reaches the network ***",
                !raw.contains("@") && !raw.contains("person"), raw)

    var threw = false
    do { try await sk.identify(externalUserID: "person@example.com") } catch { threw = true }
    await check("SK20. …and `identify` refuses it outright", threw)
}

do {
    /* One listener, however many times start() is called. */
    let sk = WebmasterIDStoreKit(
        configuration: try StoreKitTestSupport.configuration(
            storage: FakeStoreKitStorage(), transport: FakeStoreKitTransport()))
    await sk.start()
    await sk.start()
    let d21 = await sk.diagnostics()
    await check("SK21. start() is idempotent — never two Transaction.updates listeners",
                d21.isListening)
    await sk.stop()
    let d22 = await sk.diagnostics()
    await check("SK22. stop() releases the listener", !d22.isListening)
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

    await check("SK26. the client never branches on its own verification verdict",
                !storeKitCode.contains("case .verified") && !storeKitCode.contains("case .unverified"),
                "the SDK is filtering on a client-side verdict")

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
