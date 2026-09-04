# Cross-language golden fixtures

These files are the ONE definition of the M3 wire contract, and both sides are
held to them:

- the WebmasterID ingest service parses every `request.*.json` through the
  same validator its route uses, and checks every `response.*.json` against
  the shapes that route actually returns — in the service's own repository;
- the Swift SDK encodes the same requests and decodes the same responses
  (`Sources/WebmasterIDConformance/main.swift`).

The point is drift. A server and an SDK maintained in two languages diverge one
harmless-looking rename at a time, and the divergence is invisible until a
device in someone's pocket starts getting 400s. A fixture that both sides read
turns that into a failing test in whichever repository moved first.

⚠ `occurred_at` in these files is a FIXED instant. The route rejects an event
older than seven days, so a test that feeds a fixture to the live validator
must inject a clock near that instant rather than using the wall clock — see
how the golden tests do it. Rewriting the timestamps to "now" on every run
would make the fixtures non-deterministic and would silently stop testing the
age bound.
