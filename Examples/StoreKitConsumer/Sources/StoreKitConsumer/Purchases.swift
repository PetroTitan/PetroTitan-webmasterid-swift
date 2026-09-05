import Foundation
import StoreKit
import WebmasterID
import WebmasterIDStoreKit

/// The whole integration, as a customer writes it.
///
/// ⚠ THIS FILE IS COMPILED BY CI AS AN EXTERNAL CONSUMER. Building the SDK
/// proves the SDK compiles; it says nothing about whether everything a customer
/// needs is `public`. If a type or method here stops being reachable from
/// outside the package, this stops building.
@available(iOS 15.0, macOS 12.0, *)
public final class PurchaseReporting {
    private let analytics: WebmasterIDClient
    private let storeKit: WebmasterIDStoreKit

    /*
     * `async` because constructing the collector reads the core client's
     * consent and identity state — a cross-actor call. That is the shape the
     * design demands: there is no way to build it holding a second, independent
     * opinion about who the user is.
     */
    public init(appPropertyID: String) async throws {
        /*
         * ONE client owns consent and identity. The StoreKit collector is
         * constructed FROM it rather than configured beside it, so the two
         * cannot hold different opinions about who the user is or what they
         * agreed to.
         */
        analytics = WebmasterIDClient(
            configuration: try WebmasterIDConfiguration(appPropertyID: appPropertyID)
        )
        storeKit = try await WebmasterIDStoreKit.attached(to: analytics)
    }

    public func start() async {
        await storeKit.start()
    }

    /// Consent is set on the ANALYTICS client, and StoreKit follows.
    public func consentDecided(_ consent: WebmasterIDConsent) async {
        await analytics.setConsent(consent)
    }

    public func userSignedIn(accountKey: String) async throws {
        try await analytics.identify(externalUserID: accountKey)
    }

    public func userSignedOut() async {
        await analytics.resetIdentity()
    }

    /// The purchase path, including the `finish()` that is YOURS to call.
    public func buy(_ product: Product) async throws {
        let result = try await product.purchase()
        guard case let .success(verification) = result else { return }

        await storeKit.submit(verification)

        /*
         * ⚠ THE SDK NEVER FINISHES A TRANSACTION. Apple's contract is that the
         * app finishes it once the product or service has actually been
         * delivered — see Transaction.finish(). Only this code knows whether
         * the entitlement was granted.
         */
        if case let .verified(transaction) = verification {
            await grantEntitlement(for: transaction)
            await transaction.finish()
        }
    }

    private func grantEntitlement(for transaction: Transaction) async {
        _ = transaction.productID
    }

    public func report() async -> (pending: Int, listening: Bool) {
        let d = await storeKit.diagnostics()
        return (d.pending, d.isListening)
    }
}
