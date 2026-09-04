#if canImport(UIKit) && !os(watchOS)
import UIKit
import WebmasterID

/// UIKit lifecycle forwarding from an `AppDelegate`.
///
/// ⚠ COMPILED ONLY WHERE UIKit EXISTS. On the macOS toolchain used to verify
/// this repository there is no UIKit, so this file is excluded from that build
/// — which means it is written but NOT proven to compile here. That is stated
/// rather than implied: an iOS build is the only thing that would prove it.
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
