import Foundation

/// Blob storage for signed evidence.
///
/// Separate from `WebmasterIDStorage` because the guarantee is different: this
/// one must be written under file protection, and the protocol exists so a test
/// can substitute an in-memory implementation without weakening the real one.
public protocol WebmasterIDStoreKitStorage: Sendable {
    func read(_ name: String) throws -> Data?
    /// Must be ATOMIC and, on a real device, PROTECTED.
    func write(_ data: Data, to name: String) throws
    func remove(_ name: String) throws
}

/// Files in the app's Application Support directory, replaced atomically and —
/// on Apple's mobile platforms — written with complete file protection.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WHY THIS IS NOT `WebmasterIDFileStorage`
/// ═══════════════════════════════════════════════════════════════════════════
///
/// The event queue holds analytics. This holds Apple's signed evidence of a
/// purchase, which is exactly the sort of file that should not be readable off
/// a locked device. So it is written with `.completeFileProtection`, in its own
/// directory, and it never shares a file with events.
///
/// ⚠ `.completeFileProtection` MEANS THE FILE IS UNREADABLE WHILE THE DEVICE IS
/// LOCKED, AND THAT IS A REAL TRADE-OFF, NOT A FREE WIN. A background refresh
/// that runs before first unlock cannot read the queue. The SDK treats that as
/// "nothing to send yet" and retries later — losing nothing, because the host
/// app has not called `finish()` and StoreKit will re-offer the transaction.
/// The alternative, `.completeUnlessOpen`, would keep a purchase JWS readable
/// on a locked device for the sake of a delivery that can simply happen later.
public struct WebmasterIDStoreKitFileStorage: WebmasterIDStoreKitStorage {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `<Application Support>/WebmasterID/<property>/storekit/`.
    ///
    /// A subdirectory of its own so a future "clear analytics" operation that
    /// removes the event queue cannot take unacknowledged payment evidence with
    /// it by accident.
    public static func applicationSupport(scope: String) throws -> WebmasterIDStoreKitFileStorage {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("WebmasterID", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("storekit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WebmasterIDStoreKitFileStorage(directory: dir)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read(_ name: String) throws -> Data? {
        let u = url(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    public func write(_ data: Data, to name: String) throws {
        /*
         * `.atomic` for the same reason the event queue uses it: a crash
         * mid-write leaves the OLD file intact rather than half of a new one.
         *
         * `.completeFileProtection` is compiled in only where it exists.
         * ⚠ macOS HAS NO FILE PROTECTION — the option is a no-op there at best
         * and an error at worst, and the SDK builds for macOS so its
         * verification suite can run without a simulator. Guarding by platform
         * keeps the mobile guarantee real instead of silently degrading it into
         * "we asked and it did not happen".
         */
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try data.write(to: url(name), options: [.atomic, .completeFileProtection])
        #else
            try data.write(to: url(name), options: [.atomic])
        #endif
    }

    public func remove(_ name: String) throws {
        let u = url(name)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }
}
