# Changelog

## Unreleased

### Fixed

- The cancellation check in the verification suite raced a 20 ms sleep against
  a 120 ms request. On a loaded runner the flush finished first, the queue
  emptied legitimately, and the check reported a loss that had not occurred —
  which is how 1.0.0's tag-triggered CI went red on a commit whose `main` run
  was green. The transport now signals when a request is in flight and the
  test cancels at that point, so nothing depends on machine load.

## 1.0.0

The first public release of the WebmasterID Swift SDK, tagged at `c5da2a8`.

> ⚠ **Its tag-triggered CI run is red** because of the flake described above,
> not because of anything in the package: the same tree passed on `main`. A
> published tag is immutable and was not moved. The fix is forward-only.

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
