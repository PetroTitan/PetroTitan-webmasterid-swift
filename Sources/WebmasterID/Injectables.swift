import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// THE FOUR THINGS A TEST MUST BE ABLE TO CONTROL
// ═══════════════════════════════════════════════════════════════════════════
//
// Time, randomness, storage and the network. Every one of them is a global by
// default and every one of them makes a test either flaky or untestable, so
// each is an injected protocol with a real implementation and a deterministic
// one. Nothing in the SDK reads `Date()`, `UUID()`, `FileManager.default` or
// `URLSession.shared` outside these seams.

public protocol WebmasterIDClock: Sendable {
    func now() -> Date
}

public struct WebmasterIDSystemClock: WebmasterIDClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A source of opaque identifiers.
///
/// ⚠ PURPOSE-SEPARATED BY CONSTRUCTION. Callers ask for a `purpose`, and the
/// system implementation ignores it entirely — every value is independent
/// randomness from `SystemRandomNumberGenerator`. The parameter exists so that
/// a test can PROVE independence, and so nobody can later "optimise" the
/// installation id into a hash of the session id: there is no derivation to
/// change, because there is none.
public enum WebmasterIDIDPurpose: String, Sendable, CaseIterable {
    case installation, session, clientEvent
}

public protocol WebmasterIDRandomSource: Sendable {
    func opaqueIdentifier(for purpose: WebmasterIDIDPurpose) -> String
    /// A lowercase UUIDv4 — the shape the server requires for `event_id`.
    func uuidV4() -> String
}

public struct WebmasterIDSystemRandomSource: WebmasterIDRandomSource {
    public init() {}

    /// 128 bits of system randomness, base64url, unpadded.
    ///
    /// Never derived from IDFA, IDFV, the vendor identifier, the device name,
    /// the advertising identifier, the model, the IP, the user agent, the
    /// clock, or anything else about the device or the person. Those are all
    /// stable across reinstalls or across apps, which is the property that
    /// makes them identifiers rather than random values.
    public func opaqueIdentifier(for purpose: WebmasterIDIDPurpose) -> String {
        _ = purpose
        var bytes = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func uuidV4() -> String { UUID().uuidString.lowercased() }
}

// ───────────────────────────────────────────────────────────────────────────
// STORAGE
// ───────────────────────────────────────────────────────────────────────────

/// Crash-safe blob storage for the queue and the local identity record.
public protocol WebmasterIDStorage: Sendable {
    func read(_ name: String) throws -> Data?
    /// Must be ATOMIC: a reader either sees the whole previous value or the
    /// whole new one. A torn write is a corrupted queue on the next launch.
    func write(_ data: Data, to name: String) throws
    func remove(_ name: String) throws
}

/// Files in the app's Application Support directory, replaced atomically.
public struct WebmasterIDFileStorage: WebmasterIDStorage {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The default location: `<Application Support>/WebmasterID/<property>/`.
    ///
    /// Scoped by property so two clients in one app cannot share a queue, and
    /// under Application Support rather than Caches because the system may
    /// evict Caches at any time — including between a `track` and its delivery.
    public static func applicationSupport(scope: String) throws -> WebmasterIDFileStorage {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("WebmasterID", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WebmasterIDFileStorage(directory: dir)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read(_ name: String) throws -> Data? {
        let u = url(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    public func write(_ data: Data, to name: String) throws {
        /*
         * `.atomic` writes a temporary file and renames it. A crash mid-write
         * therefore leaves the OLD queue intact rather than half of a new one,
         * which is the difference between losing one batch and losing the file.
         */
        try data.write(to: url(name), options: [.atomic])
    }

    public func remove(_ name: String) throws {
        let u = url(name)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }
}

// ───────────────────────────────────────────────────────────────────────────
// TRANSPORT
// ───────────────────────────────────────────────────────────────────────────

public struct WebmasterIDHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let retryAfterSeconds: Double?

    public init(status: Int, body: Data, retryAfterSeconds: Double? = nil) {
        self.status = status
        self.body = body
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public protocol WebmasterIDTransport: Sendable {
    func send(_ request: URLRequest) async throws -> WebmasterIDHTTPResponse
}

/// `URLSession`, with the header parsing the delivery loop depends on.
public struct WebmasterIDURLSessionTransport: WebmasterIDTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> WebmasterIDHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return WebmasterIDHTTPResponse(status: 0, body: data)
        }
        return WebmasterIDHTTPResponse(
            status: http.statusCode,
            body: data,
            retryAfterSeconds: Self.retryAfter(http)
        )
    }

    /// `Retry-After` is delta-seconds or an HTTP-date. The route sends seconds;
    /// a proxy in front of it may not, so both are read.
    static func retryAfter(_ http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
