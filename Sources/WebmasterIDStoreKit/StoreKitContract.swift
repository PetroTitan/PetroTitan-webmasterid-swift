import Foundation

/// The StoreKit submission contract, v2 — and the exact list of things a client
/// is not allowed to say.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// APPLE DECIDES MONEY. THIS SDK CARRIES A SIGNATURE AND A ROUTING HINT.
/// ═══════════════════════════════════════════════════════════════════════════
///
/// The envelope holds Apple's compact signed JWS and non-financial context.
/// There is no `price`, no `currency`, no `productType`, no `transactionId`, no
/// `environment`, no `verified` flag — not filtered out downstream, but ABSENT
/// FROM THE TYPE. A struct that carried a price would have a price one refactor
/// away from being read; this one cannot regress that way, because there is no
/// field to read.
///
/// Everything authoritative is decoded from the JWS by the server, after
/// verification against Apple's root certificates. This SDK never decodes the
/// payload to decide anything.
public enum WebmasterIDStoreKitContract {
    /// v1 is the event contract. StoreKit identity submissions are v2.
    public static let envelopeVersion = 2

    public static let path = "/api/v1/mobile/storekit/transactions"

    /// The route's own field limit, in UTF-8 BYTES.
    public static let maxSignedTransactionBytes = 16 * 1024
    public static let maxBodyBytes = 32 * 1024

    /// Matches `MOBILE_MAX_EXTERNAL_USER_ID_LENGTH` on the server.
    public static let maxExternalUserIDLength = 128
}

/// What the server did with the PAYMENT.
///
/// ⚠ EVERY CASE HERE IS TERMINAL. `rejected` included: re-sending evidence
/// Apple would not vouch for never starts working, and a client that retries it
/// forever is a client whose queue never drains.
public enum WebmasterIDStoreKitPaymentOutcome: String, Sendable, Decodable, CaseIterable {
    case accepted
    case duplicate
    case rejected
}

/// What the server did with the IDENTITY — reported separately, because it
/// fails independently.
///
/// Money is durable the moment Apple's signature verifies and the row commits.
/// Linking that payment to a user can fail afterwards, or stay unresolved for
/// reasons that are not errors. One combined status would force a choice
/// between telling the client to re-send a banked payment and telling it to
/// discard evidence whose identity never converged.
public enum WebmasterIDStoreKitIdentityOutcome: String, Sendable, Decodable, CaseIterable {
    /// Resolved to a user.
    case linked
    /// No claim was sent. Not an error.
    case notProvided = "not_provided"
    /// A claim was sent, but Apple signed no `appAccountToken` to bridge it —
    /// the app did not set one at purchase. Terminal: no retry adds a token to
    /// an already-signed payload.
    case missingAppAccountToken = "missing_app_account_token"
    /// The Apple account is already claimed by a different user. Terminal, and
    /// deliberately unresolved.
    case ambiguous
    /// Transient. The payment stands; resubmitting converges the identity.
    case retryable
    /// Consent forbids linking.
    case notPermitted = "not_permitted"
}

/// The server's answer.
public struct WebmasterIDStoreKitAcknowledgement: Sendable, Decodable, Equatable {
    public let contractVersion: Int
    public let outcome: WebmasterIDStoreKitPaymentOutcome
    public let clientTransactionID: String?
    /// Absent on a v1 answer. A v1 server never speaks about identity.
    public let identity: WebmasterIDStoreKitIdentityOutcome?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case outcome
        case clientTransactionID = "client_transaction_id"
        case identity
    }

    public init(
        contractVersion: Int,
        outcome: WebmasterIDStoreKitPaymentOutcome,
        clientTransactionID: String?,
        identity: WebmasterIDStoreKitIdentityOutcome?
    ) {
        self.contractVersion = contractVersion
        self.outcome = outcome
        self.clientTransactionID = clientTransactionID
        self.identity = identity
    }

    /// May the client delete its stored evidence?
    ///
    /// ⚠ BOTH CONDITIONS, AND THE SECOND IS THE ONE THAT GETS FORGOTTEN. The
    /// payment outcome is always terminal, so a naive reading says "always
    /// yes". But a banked payment whose identity is `retryable` still needs the
    /// JWS: dropping it strands that purchase unlinked forever, because the
    /// evidence required to link it is the thing that was deleted.
    ///
    /// The retry deduplicates the payment (`duplicate`) and converges the
    /// identity, which is exactly the intended behaviour.
    public var mayDiscardEvidence: Bool {
        identity != .retryable
    }
}

/// One submission, as it goes on the wire.
///
/// ⚠ THE ABSENT FIELDS ARE THE DESIGN. Adding a stored property for anything
/// Apple signs is a product decision, not a refactor.
struct WebmasterIDStoreKitSubmission: Sendable, Encodable {
    let contractVersion: Int
    let appPropertyID: String
    /// Apple's compact JWS, verbatim. Never decoded here to decide anything.
    let signedTransaction: String
    /// Opaque, client-minted, stable across retries of THIS submission.
    ///
    /// ⚠ NOT DERIVED FROM APPLE'S TRANSACTION ID. The server echoes this value
    /// back and may log it; seeding it from `transaction.id` would put an Apple
    /// transaction identifier into logs and acknowledgements, which the privacy
    /// boundary forbids. It is random, minted once when the evidence is queued,
    /// and stored beside it.
    let clientTransactionID: String
    let consent: String
    /// Omitted entirely when there is no user to name — `nil` encodes to an
    /// absent key, not to `null`.
    let identity: Identity?

    struct Identity: Sendable, Encodable {
        let externalUserID: String

        enum CodingKeys: String, CodingKey {
            case externalUserID = "external_user_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case appPropertyID = "app_property_id"
        case signedTransaction = "signed_transaction"
        case clientTransactionID = "client_transaction_id"
        case consent
        case identity
    }
}
