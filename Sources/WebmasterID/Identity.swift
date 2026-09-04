import Foundation

/// Where a raw authenticated user identifier is allowed to live.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHY THIS IS A SEPARATE STORE AND NOT A FIELD ON THE QUEUED EVENT
/// ═══════════════════════════════════════════════════════════════════════════
///
/// An `external_user_id` is a direct identifier for a person's account. The
/// obvious design puts it on the event, and the event goes in a JSON file in
/// the app container — so every queued event would carry a durable account key
/// in plaintext on disk, for as long as delivery took, readable by anything
/// with file access and surviving a crash.
///
/// So the queue holds an EPOCH, not a value, and the value lives here: the
/// Keychain on Apple platforms, which is encrypted at rest and tied to the
/// device passcode. In tests it is an in-memory implementation, which is why
/// it is a protocol.
public protocol WebmasterIDIdentityStore: Sendable {
    func load() -> WebmasterIDStoredIdentity?
    func save(_ identity: WebmasterIDStoredIdentity)
    func clear()
}

public struct WebmasterIDStoredIdentity: Sendable, Equatable, Codable {
    /// The value the host application supplied. Never inferred, never derived.
    public let externalUserID: String
    /// Advances on every `identify` and every reset, so a queued event can be
    /// asked "were you created while THIS identity was current?".
    public let epoch: Int

    public init(externalUserID: String, epoch: Int) {
        self.externalUserID = externalUserID
        self.epoch = epoch
    }
}

/// In-memory identity, for tests and for hosts that decline the Keychain.
public final class WebmasterIDMemoryIdentityStore: WebmasterIDIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: WebmasterIDStoredIdentity?

    public init(initial: WebmasterIDStoredIdentity? = nil) { value = initial }

    public func load() -> WebmasterIDStoredIdentity? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ identity: WebmasterIDStoredIdentity) {
        lock.lock(); defer { lock.unlock() }
        value = identity
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}

#if canImport(Security)
import Security

/// Keychain-backed identity, `kSecClassGenericPassword`.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the SDK may need to
/// resolve an identity in the background after a device reboot, so
/// `WhenUnlocked` is too strict; `ThisDeviceOnly` keeps it out of iCloud
/// Keychain and off any backup that would move it to another device.
public struct WebmasterIDKeychainIdentityStore: WebmasterIDIdentityStore {
    private let account: String
    private let service = "com.webmasterid.sdk.identity"

    public init(scope: String) { account = scope }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> WebmasterIDStoredIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(WebmasterIDStoredIdentity.self, from: data)
    }

    public func save(_ identity: WebmasterIDStoredIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }
}
#endif

// ───────────────────────────────────────────────────────────────────────────
// THE LOCAL, NON-SECRET IDENTITY RECORD
// ───────────────────────────────────────────────────────────────────────────

/// Installation and session identity — pseudonymous, app-local, and safe to
/// keep beside the queue because neither identifies a person outside this app.
struct WebmasterIDLocalIdentity: Sendable, Codable, Equatable {
    /// Created only when consent permits a persistent identifier.
    var installationID: String?
    var sessionID: String
    /// When the session was last touched. The rotation rule reads this.
    var sessionLastActiveAt: Date
    /// Advances with the identity store, so the two cannot disagree.
    var identityEpoch: Int
}

enum WebmasterIDSessionRule {
    /// A new session starts after 30 minutes of inactivity, or on an explicit
    /// foreground after a background.
    ///
    /// ⚠ THE ID IS RANDOM; THE TIMESTAMP ONLY DECIDES *WHEN* TO MINT A NEW ONE.
    /// Using the wall clock as the identifier itself — `"s-\(Date())"` — would
    /// make the session id a timestamp, which is a fingerprinting surface and
    /// collides across two devices that opened the app in the same millisecond.
    static let inactivityTimeout: TimeInterval = 30 * 60

    static func isExpired(lastActiveAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastActiveAt) >= inactivityTimeout
            || now < lastActiveAt.addingTimeInterval(-inactivityTimeout)
    }
}

// ───────────────────────────────────────────────────────────────────────────
// VALIDATION OF A HOST-SUPPLIED USER ID
// ───────────────────────────────────────────────────────────────────────────

enum WebmasterIDUserIDValidator {
    /// Accepts an application's own opaque account key and nothing else.
    ///
    /// ⚠ AN `@` OR WHITESPACE IS REFUSED, MATCHING THE SERVER. An email address
    /// here is a direct identifier this product must never receive, and
    /// accepting it — even to hash it later — makes the mistake invisible to
    /// the developer who made it. Refusing tells them.
    static func validate(_ raw: String) throws -> String {
        let trimmed = raw
        guard !trimmed.isEmpty,
              trimmed.count <= WebmasterIDContract.maxExternalUserIDLength,
              !trimmed.contains("@"),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw WebmasterIDValidationError.invalidExternalUserID }
        return trimmed
    }
}
