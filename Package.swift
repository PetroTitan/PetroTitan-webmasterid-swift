// swift-tools-version: 6.0
//
// The WebmasterID Swift SDK — standalone distribution.
//
// ═══════════════════════════════════════════════════════════════════════════
// THIS REPOSITORY IS A SNAPSHOT, NOT A FORK OF A MONOREPO
// ═══════════════════════════════════════════════════════════════════════════
//
// The SDK is developed inside a private WebmasterID monorepo, where it lives
// under `sdk/swift/` and the manifest sits at the monorepo root so SwiftPM can
// resolve it. That arrangement works, and it publishes the whole monorepo's
// tags as the SDK's version namespace — which is why distribution moved here.
//
// This repository contains ONLY the MIT-licensed SDK. No private history was
// copied: it was bootstrapped as a clean snapshot, and `SOURCE_PROVENANCE.md`
// records exactly which source commit it came from and the SHA-256 of every
// exported file.
//
// The layout is therefore ordinary: `Sources/WebmasterID`, not
// `sdk/swift/Sources/WebmasterID`. Nothing else about the package changed —
// same product, same platforms, same language mode, same privacy manifest.
import PackageDescription

let package = Package(
    name: "WebmasterID",
    platforms: [
        // iOS 15 is the supported minimum. macOS 12 is listed so the package
        // builds and its verification suite RUNS on a Mac without an iOS
        // simulator, and so the core stays free of UIKit — which it must be
        // anyway, since the SDK observes no lifecycle on its own.
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "WebmasterID", targets: ["WebmasterID"]),
    ],
    targets: [
        .target(
            name: "WebmasterID",
            resources: [
                /*
                 * ⚠ `.copy`, NOT `.process`.
                 *
                 * Apple requires `PrivacyInfo.xcprivacy` at the ROOT of the
                 * resource bundle. `.process` may relocate or transform a
                 * resource by type; `.copy` places it verbatim. A manifest one
                 * directory down is one Apple's tooling never sees, and the
                 * failure is silent until App Store review.
                 */
                .copy("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        /*
         * The verification suite, as an EXECUTABLE rather than a `.testTarget`.
         *
         * XCTest and swift-testing both ship with Xcode; on a machine with
         * Command Line Tools only, neither resolves. A test target there would
         * be code that had never been compiled, presented as tests. This runs
         * — `swift run WebmasterIDConformance` — and exits non-zero on the
         * first broken guarantee.
         *
         * It links the library like any consumer, with no `@testable`, so
         * every guarantee it checks is one you can verify yourself.
         *
         * ⚠ It is a TARGET, not a PRODUCT: it is buildable here and invisible
         * to anyone who depends on this package.
         */
        .executableTarget(
            name: "WebmasterIDConformance",
            dependencies: ["WebmasterID"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
