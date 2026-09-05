// swift-tools-version: 6.0
//
// A consumer that sells something.
//
// ═══════════════════════════════════════════════════════════════════════════
// WHY A SECOND EXAMPLE AND NOT A FLAG ON THE FIRST
// ═══════════════════════════════════════════════════════════════════════════
//
// `QuickStart` exists to prove the CORE is usable on its own — and, since
// M6.2, to prove something the core alone cannot: that an app which adds only
// `WebmasterID` never builds `WebmasterIDStoreKit` and therefore never links
// StoreKit. That is only demonstrable by a package that does NOT depend on it.
//
// This one is the other half of the pair: it takes both products, so the
// StoreKit module IS in its build. The two builds together are the evidence.
import PackageDescription

let package = Package(
    name: "StoreKitConsumer",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "StoreKitConsumer", targets: ["StoreKitConsumer"])],
    dependencies: [.package(name: "WebmasterID", path: "../..")],
    targets: [
        .target(
            name: "StoreKitConsumer",
            /*
             * ⚠ SEE QuickStart's NOTE ON `.package(name:path:)`. A path
             * dependency is identified by its DIRECTORY name, so the explicit
             * `name:` is what makes `package: "WebmasterID"` resolve in both a
             * developer's clone and CI. A customer using a URL dependency
             * writes `package: "petrotitan-webmasterid-swift"` instead.
             */
            dependencies: [
                .product(name: "WebmasterID", package: "WebmasterID"),
                .product(name: "WebmasterIDStoreKit", package: "WebmasterID"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
