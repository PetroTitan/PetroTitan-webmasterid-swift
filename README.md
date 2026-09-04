# WebmasterID Swift SDK

Privacy-safe analytics events from an iOS app to WebmasterID mobile ingest.

**This SDK sends analytics events. It does not report verified conversions.**
Revenue, purchases, subscriptions, refunds and StoreKit verification are not
implemented — the ingest route refuses those fields, and this SDK has no way to
express them.

---

## Status

| | |
| --- | --- |
| Source on `main` | the current snapshot |
| Stable release | **`1.0.0` is planned and not yet tagged** |

> Until the `1.0.0` tag exists, `from: "1.0.0"` will not resolve. Depend on a
> branch or a revision in the meantime.

## Install

```swift
.package(
    url: "https://github.com/PetroTitan/PetroTitan-webmasterid-swift.git",
    from: "1.0.0"
)
```

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "WebmasterID", package: "petrotitan-webmasterid-swift")]
)
```

> SwiftPM derives a package's identity from the URL's last path component,
> lowercased — hence `petrotitan-webmasterid-swift`, not the manifest's
> `name`.

**Minimum iOS 15.** Swift tools 6.0, Swift 6 language mode, strict
concurrency. **No third-party dependencies** — Foundation, and Security for
the Keychain.

## Quick start

```swift
import WebmasterID

let client = WebmasterIDClient(
    configuration: try WebmasterIDConfiguration(
        appPropertyID: "ap_xxxxxxxxxxxxxxxx",   // yours, from the dashboard
        consent: .notDetermined                  // collects nothing yet
    )
)

await client.setConsent(.analyticsAllowed)
try await client.track(.screenView, context: .init(screen: "BookingDetail"))
await client.flush()
```

The app property identifier is **public**: it ships inside your binary and
anyone can read it out. It addresses your property; it is not a credential.
**Never put a WebmasterID server key in an app.**

Full guide: [`docs/Integration.md`](docs/Integration.md).
Worked example: [`Examples/QuickStart`](Examples/QuickStart).

## Consent

Three states. The client starts at `.notDetermined`, which collects nothing —
no event queued, none written to disk, none sent, no persistent identifier
created. Consent is enforced **before queue insertion**, not merely before the
network.

```swift
await client.setConsent(.analyticsAllowed)  // events + pseudonymous identifiers
await client.setConsent(.restricted)        // events only, no stable identifiers
await client.setConsent(.disabled)          // stop, and delete what was kept
```

## What it will not do

- no StoreKit, purchases, revenue, subscriptions or refunds
- no IDFA, IDFV, AppTrackingTransparency or advertising identifier
- no Location Services, no precise location; region and city are never collected
- no device fingerprinting, no method swizzling, no automatic screen tracking
- no arbitrary metadata dictionary — event names are a closed enum
- **no guaranteed background delivery**: iOS gives a backgrounding app a short,
  unguaranteed window. Undelivered events are retried on the next launch; that
  is the guarantee, and no background `URLSession` is implemented.

## Privacy manifest

`PrivacyInfo.xcprivacy` ships as a package resource, at the root of the
resource bundle. `NSPrivacyTracking` is **false**, there are no tracking
domains, and `NSPrivacyAccessedAPITypes` is **empty** — audited API by API.

## Verify it yourself

```bash
swift build
swift run WebmasterIDConformance          # 67 guarantees, through the public API only
swift build --package-path Examples/QuickStart
```

## Licence

**MIT** — [`LICENSE`](LICENSE), copyright (c) 2026 PetroTitan.

⚠ The licence covers **this SDK's source**. WebmasterID is not an open-source
platform: the dashboard, the ingest API and the rest of the service are not in
this repository and are not MIT-licensed. No rights are granted to WebmasterID
**trademarks, service marks, product names or branding**, nor to the hosted
services or any data they hold.

## Provenance

Bootstrapped as a clean snapshot from the private WebmasterID monorepo. No
private history was copied. See [`SOURCE_PROVENANCE.md`](SOURCE_PROVENANCE.md)
for the exact source commit and a SHA-256 manifest of every exported file.
