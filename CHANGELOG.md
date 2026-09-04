# Changelog

## 1.0.0 — unreleased

The first public release of the WebmasterID Swift SDK.

> **Not yet tagged.** This entry describes what `1.0.0` will contain. Until the
> tag exists, `from: "1.0.0"` does not resolve.

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
