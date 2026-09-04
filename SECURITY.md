# Security policy

## Reporting

Report a suspected vulnerability privately, through GitHub's **“Report a
vulnerability”** button on this repository's Security tab. Please do not open a
public issue for a security problem.

Include what you did, what you observed, and what you expected. A proof of
concept helps; a working exploit is not required.

## Scope

**In scope:** this repository — the `WebmasterID` Swift library, its
verification suite, the example, and the packaging that distributes them.

**Out of scope here:** the WebmasterID hosted service, the ingest API, the
dashboard and the browser tracker. None of them is in this repository. Report
those to WebmasterID directly.

## What this SDK deliberately does not hold

Knowing this narrows a real report from a theoretical one. The SDK cannot send
or store an advertising identifier, a vendor identifier, a device model, a raw
user agent, a precise or coarse location, a URL, a query string, arbitrary
metadata, or any payment or revenue value — the fields do not exist.

An authenticated account key, when your app supplies one, is kept in the
**Keychain** and never written into the on-disk event queue.

**Please do not include real user identifiers, account keys or production app
property IDs in a report.** A redacted description is enough.
