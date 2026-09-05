# Changelog

## Unreleased

### Added

- **`WebmasterIDStoreKit` — a new, OPTIONAL product.** Add it to a target only
  if the app sells something. `WebmasterID` does not depend on it and does not
  import StoreKit; the dependency runs one way.

  ```swift
  .product(name: "WebmasterIDStoreKit", package: "petrotitan-webmasterid-swift")
  ```

  It observes `Transaction.updates`, accepts an explicit
  `VerificationResult<Transaction>` from `Product.purchase`, and submits Apple's
  signed `jwsRepresentation` for server-side verification.

- **A protected, separate evidence queue.** Unacknowledged signed transactions
  are stored under `.completeFileProtection` on Apple's mobile platforms, in
  their own file, with their own bounds. They are never mixed with the analytics
  event queue — whose eviction policy would be free to discard a purchase to
  make room for screen views.

- **Identity association through Apple's signed `appAccountToken`.** Set
  `externalUserID` and a purchase resolves to the SAME pseudonymous user as that
  app's mobile events, so a paying customer's journey opens.

### What this SDK will not do

- **It never calls `transaction.finish()`.** Finishing is your decision: only
  your app knows whether the entitlement was delivered. Call it yourself.
- **It never tells the server what a purchase was worth.** The envelope has no
  field for price, currency, product type, transaction id, environment or
  verification status. Apple signs those; the server reads them from the
  signature.
- **It never filters on its own verification verdict.** `.verified` and
  `.unverified` are both submitted, because a stale device trust store is not
  evidence that a payment is fake.

### Retention, stated plainly

The raw JWS is written to disk on the device, in the protected queue, until the
server acknowledges it — a queue that discarded the signature could not retry,
and a purchase made offline would be lost. It is never persisted server-side.

### Unchanged

- The `WebmasterID` core: same public API, same behaviour, same privacy
  manifest, still zero dependencies. An app that does not add the new product
  sees no difference.

## 1.0.1 — 2026-09-04

**The SDK itself is byte-for-byte identical to 1.0.0.** No runtime source, no
public API, no `Package.swift`, no `PrivacyInfo.xcprivacy`, no LICENSE and no
dependency changed. If you are on 1.0.0 and it works, nothing here fixes a
problem you have.

What changed is the release verification, and why that mattered enough to cut a
version for it.

### Fixed

- **The cancellation check is deterministic.** It raced a 20 ms sleep against a
  120 ms request. On a loaded runner the flush finished first, the queue
  emptied *legitimately*, and the check reported a loss that had not occurred.
  The transport now signals when a request is in flight and the test cancels at
  that point, so nothing depends on how busy the machine is.

  That flake is why 1.0.0's tag-triggered CI went red on a commit whose `main`
  run was green. A release gate that turns on machine load cannot tell a
  regression from a bad afternoon — so 1.0.1 exists to give the same code a
  release whose verification means something.

### Unchanged

Consent behaviour, the offline queue, retry and idempotency semantics, the
privacy manifest, the iOS 15 minimum, and the continued absence of StoreKit,
trusted revenue, advertising identifiers, location and arbitrary metadata.

## 1.0.0

The first public release of the WebmasterID Swift SDK, tagged at `c5da2a8`.

> ⚠ **Its tag-triggered CI run is red** because of the flake described under
> 1.0.1 — a timing-dependent test in the release verification, not a defect in
> the package. The same tree passed on `main`. **1.0.0 remains immutable and
> was never moved**; the correction is forward-only, which is the only honest
> direction once a version is published.

### Added

- `WebmasterIDClient`, an actor — no shared singleton, so an app or a test may
  hold several isolated instances.
- Three-state consent (`analyticsAllowed`, `restricted`, `disabled`), enforced
  **before** an event is queued rather than before it is sent.
- A durable, bounded, FIFO offline queue. Events are persisted before the first
  delivery attempt, so a process killed mid-request retries on the next launch
  under the same `client_event_id`.
- Pseudonymous identity: a random, resettable installation identifier and an
  optional account key the host supplies. The account key lives in the
  **Keychain**, never in the on-disk queue.
- Delivery semantics: byte-accurate batching within the route's 48 KiB limit,
  `Retry-After` honoured on 429, bounded full-jitter backoff on 5xx, permanent
  handling of 400, and cancellation that preserves unacknowledged work.
- Privacy-safe diagnostics — counts, categories and times, never payloads,
  identifiers or URLs.
- `PrivacyInfo.xcprivacy`, packaged at the resource-bundle root.
- A 67-guarantee verification suite that runs through the public API only.

### Deliberately absent

StoreKit, trusted revenue, arbitrary metadata, advertising identifiers,
AppTrackingTransparency, Location Services, device fingerprinting, method
swizzling and automatic screen tracking. Region and city are never collected;
country is derived server-side.

`uptime_delta_ms` is not implemented while the Apple 35F9.1 question is open,
and no system-uptime substitute was used in its place.
