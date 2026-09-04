# Source provenance

This repository was **bootstrapped as a clean snapshot**. No Git history from
the source repository was copied — not by `filter-repo`, not by a subtree, not
by a mirror push. The first commit here is the first commit that exists here.

| | |
| --- | --- |
| Source repository | `PetroTitan/webmasterid` (private) |
| Source commit | `30d4099ad26767b1ff046245928ebec711d8738f` |
| Export date | 2026-09-04 |
| Exported source paths | `sdk/swift/Sources/WebmasterID`, `sdk/swift/Sources/WebmasterIDConformance`, `sdk/swift/examples/QuickStart`, `sdk/swift/LICENSE`, `docs/mobile/ios-integration.md` |
| Files exported | 34 |
| Manifest SHA-256 | `ca7d10416c3f3e4c6525a2dcf8f4da42cd922c3e122b7d5079a0d43321c13ea5` |
| Licence | MIT — see [`LICENSE`](LICENSE) |

## What was deliberately left behind

The source repository is a monorepo. Its dashboard, ingest service, database
layer, browser tracker, migrations, environment files and CI unrelated to this
package were **not** exported, and neither was any credential, customer fixture
or production identifier.

One SDK target was also left behind: an integration binary that drives the
ingest service over a local socket. It cannot run without the private service,
so shipping it here would have been shipping a test that nobody outside can
execute.

## Intentional differences from the source

A snapshot is not a copy: the package had to become standalone. These files
differ from their source counterparts on purpose, and the manifest below
reflects the exported bytes, not the originals.

| File | Change |
| --- | --- |
| `Examples/QuickStart/Package.swift` | path dependency re-pointed for the flattened layout |
| `Sources/WebmasterID/Contract.swift` | doc comment: private module and fixture paths replaced with public ones |
| `Sources/WebmasterIDConformance/Fixtures/README.md` | removed a private repository file path; the cross-language claim is unchanged |
| `docs/Integration.md` | relocated paths, public package URL and identity, licence links |
| `Package.swift` | rewritten for a standalone layout: `Sources/…` rather than `sdk/swift/Sources/…` |

Everything else is byte-identical to the source at the commit above.

## Verifying this snapshot

Recompute the manifest and compare the single hash:

```bash
find . -type f -not -path './.build/*' -not -path './.git/*' \
  -not -name SOURCE_PROVENANCE.md | sort | xargs shasum -a 256 \
  | shasum -a 256
```

## Manifest

```
80e7cf369e772285cd9adfedc90870540f34f2576b5063fd62ad91ae07f6c181  .gitignore
01cb8bcced2ea8dee137c85ea6726432404f2baca755da12e331798a58f4ee14  CHANGELOG.md
97558f0e8f5a867465d94ba7d06620c6a7fbdf091d30a4ea0943fa15d42b1643  Examples/QuickStart/Package.swift
86f95fa72f24826f82f399335673141ac1ab7a3449c333f1a4c387020f9c5e34  Examples/QuickStart/Sources/QuickStart/Analytics.swift
0a09a9161cfeb30a2d8a27789eabf09b0d8d521ac1af3cce2fa2946ae57997f6  Examples/QuickStart/Sources/QuickStart/SwiftUIIntegration.swift
d57c5a574620465f637edb53a00757ec1ff3a7d3a96191a8e49b74e8dc62e79c  Examples/QuickStart/Sources/QuickStart/UIKitIntegration.swift
6a4bf09b29f115188a2f196e27c3d540c8cbff27a67ed340fd548db7c32d9a48  LICENSE
a87d3913b07a2de55a19e24d4088a0a90b327ac45e654dd848f690590a0f7b18  Package.swift
b0bc60eef10bdc0ddf71553de10331c0dbec4df940ce833951d634e7a5d9ab3c  README.md
cb6ebfe7ff2f85b937470a62bf53bc38f62fde3fbcb0b2a2e2c74ea006eddd24  SECURITY.md
012747e03905505244069490b74de7a821658ce25ccf4d80487b66be636f3cd6  Sources/WebmasterID/Configuration.swift
998c01ec3919ac9f14d4ef59cd57e03020c3a61910606aaeb511c6fe3029c89f  Sources/WebmasterID/Contract.swift
44911ee83976abf8720b3ab2a48f1306eca51189c01afa3ebd729f1bcc568113  Sources/WebmasterID/Delivery.swift
ede51a34db5a682e8309da27faa00bd3346f1195202c8aeae39c8f5e833516a0  Sources/WebmasterID/Diagnostics.swift
6a662ba085cff4e496cb4315e63a59d060ce74794762ab6cbf2192668af7c039  Sources/WebmasterID/Event.swift
1a61a07077a23f1e181c0085a6641154d021e4e6d7cc6f009f094d22d2e970a5  Sources/WebmasterID/Identity.swift
0f4af9b11c54916b70b8397288cd2747f24270a1c97732d8710491dd0ed74400  Sources/WebmasterID/Injectables.swift
478c54c8c807312a1353434b6d75656174ac993d6480eefc6ea67e34fe2fb24b  Sources/WebmasterID/PrivacyInfo.xcprivacy
58173d756ea0290f2d449ec6e880eae92d6e59aa799fdbb67077ccd59b399fb8  Sources/WebmasterID/Queue.swift
67cce11bb215b105ded0d161f0119c71fe1b75e969843e2eec8f19cf740e6293  Sources/WebmasterID/WebmasterIDClient.swift
2154984b89085abd2603f75624c3d6df9282c8280f9100f437211051b0d5ae52  Sources/WebmasterIDConformance/Fixtures/README.md
877310084eea61c9e6708a869d7398ac8c1316981d0f3ffe2f39f7f294cfccca  Sources/WebmasterIDConformance/Fixtures/request.identified.json
fa8cf055aff7b55882dc14b9c48eae43a68bdc3ff61729f408b98adb038fc23d  Sources/WebmasterIDConformance/Fixtures/request.maxbatch.json
b08c925e345caf3227588fb3d933c5d9b72786bbef76551007142763245f4fc3  Sources/WebmasterIDConformance/Fixtures/request.minimal.json
75196212dab72fbf74b53ab13798b18f5fd4c7da6b1b6eb5d2555304f7de59aa  Sources/WebmasterIDConformance/Fixtures/request.restricted.json
cb924d93565a7c0aacdceee9dd7c56ce5a19f67c1b1d9d6d0dad1516f8ec70e8  Sources/WebmasterIDConformance/Fixtures/response.acknowledgement.forward.json
6c5aa5905b2daa6a765fcc5f5974c9a20706bd537b42636ad0e9cecf21841a67  Sources/WebmasterIDConformance/Fixtures/response.acknowledgement.json
26bb824399d9a50fcc4ec662d4c6244228f538b4f16503b39640ecfa2d897a0e  Sources/WebmasterIDConformance/Fixtures/response.error.ratelimited.json
5b373001d8e865f5206b42cd5370443975458db32465bd820d643b6508343556  Sources/WebmasterIDConformance/Fixtures/response.error.refused.json
0b5bff7a0c66628b2a346ef1c5073b02d449244ab7e9309064f9b17754700f67  Sources/WebmasterIDConformance/Fixtures/response.error.retryable.json
cf50091171eefebd92c655a997c2a999c84e308b69b541eb4fa077d479caebb1  Sources/WebmasterIDConformance/Fixtures/response.error.validation.json
179424f457a33568c17114a61d7da9d86c6098387f6373c64c48bbfa8ceeba9b  Sources/WebmasterIDConformance/TestDoubles.swift
06541b656d2c784c86ee2c0b8b2a19c379e4add63b363c394968c8613f669da0  Sources/WebmasterIDConformance/main.swift
10aa91a896b1e402667ae8c22cc11a3253724dac3bcafb60bdc37849f4730d97  docs/Integration.md
```
