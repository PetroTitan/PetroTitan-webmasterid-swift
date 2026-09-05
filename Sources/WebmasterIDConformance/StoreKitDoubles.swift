import Foundation
import WebmasterID
import WebmasterIDStoreKit

/// In-memory protected storage — inspectable, corruptible, survivable.
final class FakeStoreKitStorage: WebmasterIDStoreKitStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private(set) var writes = 0

    func read(_ name: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[name]
    }

    func write(_ data: Data, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[name] = data
        writes += 1
    }

    func remove(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: name)
    }

    func corrupt(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        files[name] = Data("{ not json".utf8)
    }

    func raw(_ name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return files[name].map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted()
    }
}

/// A transport that answers with a scripted acknowledgement and records bodies.
final class FakeStoreKitTransport: WebmasterIDTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var bodies: [Data] = []
    private(set) var urls: [URL] = []
    private var script: [(status: Int, body: Data)] = []
    private var failNext = 0

    func enqueue(status: Int = 200, payment: String = "accepted", identity: String? = nil) {
        let json: String
        if let identity {
            json = """
                {"contract_version":2,"outcome":"\(payment)","client_transaction_id":null,"identity":"\(identity)"}
                """
        } else {
            json = """
                {"contract_version":1,"outcome":"\(payment)","client_transaction_id":null}
                """
        }
        lock.lock(); defer { lock.unlock() }
        script.append((status, Data(json.utf8)))
    }

    func enqueueRaw(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        script.append((status, Data(body.utf8)))
    }

    func failOnce() {
        lock.lock(); defer { lock.unlock() }
        failNext += 1
    }

    struct Boom: Error {}

    func send(_ request: URLRequest) async throws -> WebmasterIDHTTPResponse {
        /*
         * `NSLock.lock()` is unavailable from an async context — the same rule
         * `FakeTransport` documents. The critical section suspends at no point,
         * so it is a synchronous helper the async function calls.
         */
        try record(request).get()
    }

    private func record(_ request: URLRequest) -> Result<WebmasterIDHTTPResponse, Error> {
        lock.lock(); defer { lock.unlock() }
        bodies.append(request.httpBody ?? Data())
        if let url = request.url { urls.append(url) }
        if failNext > 0 {
            failNext -= 1
            return .failure(Boom())
        }
        let fallback = (
            200,
            Data(#"{"contract_version":1,"outcome":"accepted","client_transaction_id":null}"#.utf8)
        )
        let next = script.isEmpty ? fallback : script.removeFirst()
        return .success(WebmasterIDHTTPResponse(status: next.0, body: next.1))
    }

    func object(_ index: Int) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard index < bodies.count,
            let o = try? JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any]
        else { return [:] }
        return o
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return bodies.count
    }
}

enum StoreKitTestSupport {
    /// A representative compact JWS. Structure only — nothing here is verified
    /// on the client, and the conformance suite has no App Store to sign with.
    static func jws(_ tag: String) -> String {
        "eyJhbGciOiJFUzI1NiJ9.eyJ0cmFuc2FjdGlvbklkIjoiXCh0YWcpIn0.\(tag)signature"
    }

    static func configuration(
        storage: any WebmasterIDStoreKitStorage,
        transport: any WebmasterIDTransport,
        consent: WebmasterIDConsentState = .decided(.analyticsAllowed),
        externalUserID: String? = nil,
        maxPending: Int = 128
    ) throws -> WebmasterIDStoreKitConfiguration {
        try WebmasterIDStoreKitConfiguration(
            appPropertyID: "ap_0123456789abcdef",
            consent: consent,
            externalUserID: externalUserID,
            maxPendingSubmissions: maxPending,
            transport: transport,
            clock: FakeClock(),
            random: FakeRandomSource(),
            storage: storage
        )
    }
}
