import Foundation

/// The bridge between this core and OPTIONAL package extensions.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// GENERIC ON PURPOSE — THE CORE MUST NOT KNOW WHAT IS EXTENDING IT
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Nothing here names StoreKit, purchases, or revenue, and nothing here would
/// need renaming if a second extension appeared. The core's job is to be the
/// SINGLE authority on consent and identity; an extension's job is to obey it.
/// Naming the extension in the core would invert that.
///
/// ⚠ `package`, NOT `public`. A host application must never be able to read a
/// raw account key back out of this SDK: `resolveExternalUserID(forEpoch:)`
/// exists so a queued item can be resolved AT DELIVERY, inside the package, and
/// nowhere else. There is deliberately no public getter for the raw value —
/// only `WebmasterIDClient` writes it and only the package reads it.

/// What an extension is allowed to observe about the core's state.
///
/// ⚠ NO RAW IDENTIFIER. The epoch is an opaque counter: an extension can ask
/// "is the identity that was current when I queued this item STILL current?"
/// without ever holding the account key that identity refers to.
package struct WebmasterIDExtensionContext: Sendable, Equatable {
    package let consent: WebmasterIDConsentState
    package let identityEpoch: Int

    package init(consent: WebmasterIDConsentState, identityEpoch: Int) {
        self.consent = consent
        self.identityEpoch = identityEpoch
    }

    package var permitsCollection: Bool { consent.permitsCollection }
    package var permitsPersistentIdentifiers: Bool { consent.permitsPersistentIdentifiers }
}

/// An extension that must react when consent or identity changes.
///
/// ⚠ HELD WEAKLY BY THE CLIENT. An extension that outlives its host is a leak;
/// an extension the host cannot deallocate because the analytics client is
/// holding it is worse. The client keeps a weak reference, so registering costs
/// the host nothing in lifetime.
package protocol WebmasterIDExtensionObserver: AnyObject, Sendable {
    func webmasterIDStateDidChange(_ context: WebmasterIDExtensionContext) async
}

/*
 * ⚠ THE `extension WebmasterIDClient` METHODS LIVE IN `WebmasterIDClient.swift`,
 * NOT HERE.
 *
 * They need `consentState` and `identity`, which are `private` — and Swift's
 * `private` is file-scoped, so an extension in this file could not reach them.
 * The alternative was widening two stored properties to `internal` for the
 * convenience of file layout, which trades real encapsulation for tidiness.
 * The generic bridge TYPES stay here; the client's conformance to them sits
 * with the state it reads.
 */
