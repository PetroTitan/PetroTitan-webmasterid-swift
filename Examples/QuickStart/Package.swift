// swift-tools-version: 6.0
//
// A CONSUMER, NOT PART OF THE SDK.
//
// This package exists to prove one thing the SDK's own build cannot: that a
// separate module, depending on the published product and importing it the way
// a customer does, compiles against the PUBLIC API alone. Building the SDK
// proves the SDK compiles; it says nothing about whether anything a customer
// needs is actually `public`.
//
// ⚠ THE PATH DEPENDENCY IS DELIBERATE AND IS *NOT* THE INSTALL ROUTE.
// It points at this repository's root so the example compiles from a fresh
// clone, including before any version tag exists. A consumer uses the URL form
// shown in `README.md`; the CI workflow proves that form separately, in a
// clean directory with no access to this checkout.
import PackageDescription

let package = Package(
    name: "QuickStart",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "QuickStart", targets: ["QuickStart"])],
    dependencies: [.package(name: "WebmasterID", path: "../..")],
    targets: [
        .target(
            name: "QuickStart",
            /*
             * ⚠ THE `name:` ON THE DEPENDENCY ABOVE IS LOAD-BEARING.
             *
             * SwiftPM identifies a PATH dependency by its DIRECTORY NAME, not
             * by the manifest's `name`. Without `.package(name:path:)` this
             * fails with "unknown package 'WebmasterID'; valid packages are:
             * 'wt-main'" — the identity becomes whatever the checkout folder
             * happens to be called, which differs between a developer's clone
             * and CI. The bare by-name target dependency does not resolve it
             * either.
             *
             * A CUSTOMER HAS THE OPPOSITE PROBLEM AND THE SIMPLER ANSWER: a
             * URL dependency's identity is derived from the URL, so theirs is
             * `package: "webmasterid"`. The integration guide shows that form,
             * and `package-acceptance.mjs` proves it against the real GitHub
             * URL rather than assuming it.
             */
            dependencies: [.product(name: "WebmasterID", package: "WebmasterID")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
