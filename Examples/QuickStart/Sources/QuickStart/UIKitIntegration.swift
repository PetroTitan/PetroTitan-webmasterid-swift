#if canImport(UIKit) && !os(watchOS)
import UIKit
import WebmasterID

/// UIKit lifecycle forwarding from an `AppDelegate`.
///
/// ⚠ COMPILED ONLY WHERE UIKit EXISTS. macOS has none, so a `swift build` on
/// a Mac skips this file entirely — it is the iOS job in CI that compiles it,
/// and that job is the only thing that proves it works.
/*
 * ⚠ `@MainActor`, AND IT IS A CORRECTNESS FIX RATHER THAN AN ANNOTATION.
 *
 * Swift 6 rejected this file with
 *
 *   error: passing closure as a 'sending' parameter risks causing data races
 *          between code in the current task and concurrent execution of the
 *          closure
 *
 * `Task.init` takes a `sending` closure, and these methods were nonisolated on
 * a non-Sendable class — so capturing `self` handed a reference across
 * isolation domains with nothing preventing concurrent access.
 *
 * `UIApplicationDelegate` callbacks arrive on the main thread; the type was
 * always main-actor in practice and simply had not said so. Declaring it makes
 * the `Task` inherit that isolation, and the capture is no longer a crossing.
 *
 * ⚠ AND THIS FILE HAD NEVER BEEN COMPILED. macOS has no UIKit, so
 * `#if canImport(UIKit)` excluded it from every build this package had ever
 * had. The first iOS build is what surfaced it — which is the entire argument
 * for the iOS gate: a macOS `swift build` cannot see a file it never compiles.
 */
@MainActor
public final class AnalyticsAppDelegateBridge: NSObject {
    private let lifecycle: AnalyticsLifecycle

    public init(lifecycle: AnalyticsLifecycle) {
        self.lifecycle = lifecycle
        super.init()
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        Task {
            do { try await lifecycle.openedApp() }
            catch { AnalyticsFailure.report(error, from: "applicationDidBecomeActive") }
        }
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        Task { await lifecycle.enteredBackground() }
    }
}
#endif
