#if canImport(SwiftUI)
import SwiftUI
import WebmasterID

/// SwiftUI lifecycle forwarding via `scenePhase`.
///
/// The SDK imports no UI framework and installs no observers, so this is where
/// an app connects the two. Doing it here rather than inside the SDK is why
/// there is no swizzling: nothing is patched, and an app that wants different
/// behaviour simply writes different code.
@available(iOS 15, macOS 12, *)
public struct AnalyticsSceneModifier: ViewModifier {
    private let lifecycle: AnalyticsLifecycle
    @Environment(\.scenePhase) private var scenePhase

    public init(lifecycle: AnalyticsLifecycle) { self.lifecycle = lifecycle }

    public func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { phase in
            Task {
                switch phase {
                case .active:
                    /* A lifecycle hook is the app boundary: it cannot throw,
                     * so it decides. See `AnalyticsFailure`. */
                    do { try await lifecycle.openedApp() }
                    catch { AnalyticsFailure.report(error, from: "scenePhase.active") }
                case .background:
                    await lifecycle.enteredBackground()
                default: break
                }
            }
        }
    }
}

@available(iOS 15, macOS 12, *)
public extension View {
    func webmasterIDAnalytics(_ lifecycle: AnalyticsLifecycle) -> some View {
        modifier(AnalyticsSceneModifier(lifecycle: lifecycle))
    }
}
#endif
