import Foundation
import WebmasterID

/// Deterministic replacements for the four things that would otherwise make
/// every test in this suite flaky: time, randomness, storage and the network.

final class FakeClock: WebmasterIDClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_788_000_000)) { current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

/// Counts identifiers per purpose so a test can prove they are independent.
final class FakeRandomSource: WebmasterIDRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [WebmasterIDIDPurpose: Int] = [:]
    private var uuidCounter = 0
    private(set) var issued: [(WebmasterIDIDPurpose, String)] = []

    func opaqueIdentifier(for purpose: WebmasterIDIDPurpose) -> String {
        lock.lock(); defer { lock.unlock() }
        let n = (counters[purpose] ?? 0) + 1
        counters[purpose] = n
        let value = "\(purpose.rawValue)-\(n)"
        issued.append((purpose, value))
        return value
    }

    func uuidV4() -> String {
        lock.lock(); defer { lock.unlock() }
        uuidCounter += 1
        /* A real UUIDv4 shape — version nibble 4, variant nibble 8. */
        return String(format: "b3f1c2d4-5e6f-4a7b-8c9d-0e1f2a3b%04x", uuidCounter)
    }

    func count(for purpose: WebmasterIDIDPurpose) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counters[purpose] ?? 0
    }
}

/// In-memory storage that can be inspected, corrupted and survived.
final class FakeStorage: WebmasterIDStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private(set) var writeCount = 0

    init(seed: [String: Data] = [:]) { files = seed }

    func read(_ name: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[name]
    }

    func write(_ data: Data, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[name] = data
        writeCount += 1
    }

    func remove(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: name)
    }

    func raw(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[name]
    }

    func corrupt(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        files[name] = Data("{ this is not the queue you are looking for".utf8)
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted()
    }
}

/// A transport that records every request and answers from a script.
final class FakeTransport: WebmasterIDTransport, @unchecked Sendable {
    struct Sent: Sendable {
        let body: Data
        let url: URL
    }

    private let lock = NSLock()
    private var responses: [Result<WebmasterIDHTTPResponse, Error>] = []
    private var fallback: Result<WebmasterIDHTTPResponse, Error>
    private(set) var sent: [Sent] = []

    init(always status: Int = 200, body: String = #"{"accepted":1,"deduplicated":0,"rejected":0}"#) {
        fallback = .success(WebmasterIDHTTPResponse(status: status, body: Data(body.utf8)))
    }

    func enqueue(_ response: WebmasterIDHTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        responses.append(.success(response))
    }

    func enqueue(status: Int, body: String = "{}", retryAfter: Double? = nil) {
        enqueue(WebmasterIDHTTPResponse(status: status, body: Data(body.utf8), retryAfterSeconds: retryAfter))
    }

    func enqueueFailure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        responses.append(.failure(error))
    }

    func setFallback(status: Int, body: String = "{}") {
        lock.lock(); defer { lock.unlock() }
        fallback = .success(WebmasterIDHTTPResponse(status: status, body: Data(body.utf8)))
    }

    func send(_ request: URLRequest) async throws -> WebmasterIDHTTPResponse {
        /*
         * `NSLock.lock()` is unavailable from an async context — holding a
         * non-async lock across a suspension is exactly how a task deadlocks
         * an executor thread. The critical section here suspends at no point,
         * so it is expressed as a synchronous helper the async function calls.
         */
        let next = record(request)
        return try next.get()
    }

    private func record(_ request: URLRequest) -> Result<WebmasterIDHTTPResponse, Error> {
        lock.lock(); defer { lock.unlock() }
        sent.append(Sent(body: request.httpBody ?? Data(), url: request.url!))
        return responses.isEmpty ? fallback : responses.removeFirst()
    }

    var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return sent.map(\.body)
    }

    func json(_ index: Int) -> [String: Any]? {
        guard index < bodies.count else { return nil }
        return try? JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any]
    }

    func events(_ index: Int) -> [[String: Any]] {
        (json(index)?["events"] as? [[String: Any]]) ?? []
    }
}

struct FakeTransportError: Error {}

// ───────────────────────────────────────────────────────────────────────────

enum TestSupport {
    static let propertyID = "ap_0123456789abcdef"

    static func configuration(
        consent: WebmasterIDConsentState = .decided(.analyticsAllowed),
        storage: FakeStorage = FakeStorage(),
        transport: any WebmasterIDTransport = FakeTransport(),
        clock: FakeClock = FakeClock(),
        random: FakeRandomSource = FakeRandomSource(),
        identityStore: WebmasterIDMemoryIdentityStore = WebmasterIDMemoryIdentityStore(),
        maxBatchBytes: Int = WebmasterIDContract.maxBodyBytes,
        maxQueuedEvents: Int = 1_000,
        maxQueuedBytes: Int = 512 * 1024,
        maxEventAge: TimeInterval = WebmasterIDContract.maxEventAge,
        maxDeliveryAttempts: Int = 8,
        externalUserID: String? = nil
    ) throws -> WebmasterIDConfiguration {
        try WebmasterIDConfiguration(
            appPropertyID: propertyID,
            baseURL: URL(string: "http://127.0.0.1:9999")!,
            consent: consent,
            externalUserID: externalUserID,
            maxBatchBytes: maxBatchBytes,
            maxQueuedEvents: maxQueuedEvents,
            maxQueuedBytes: maxQueuedBytes,
            maxEventAge: maxEventAge,
            maxDeliveryAttempts: maxDeliveryAttempts,
            transport: transport,
            clock: clock,
            random: random,
            storage: storage,
            identityStore: identityStore
        )
    }

    static func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        guard let url else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"])
        }
        return try Data(contentsOf: url)
    }

    static func fixtureObject(_ name: String) throws -> [String: Any] {
        let data = try fixture(name)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// A transport that suspends long enough for a cancellation to land while a
/// request is genuinely in flight, then succeeds.
final class SlowTransport: WebmasterIDTransport, @unchecked Sendable {
    private let delay: UInt64

    init(milliseconds: UInt64 = 120) { delay = milliseconds * 1_000_000 }

    func send(_ request: URLRequest) async throws -> WebmasterIDHTTPResponse {
        _ = request
        try await Task.sleep(nanoseconds: delay)
        return WebmasterIDHTTPResponse(
            status: 200,
            body: Data(#"{"accepted":1,"deduplicated":0,"rejected":0}"#.utf8)
        )
    }
}
