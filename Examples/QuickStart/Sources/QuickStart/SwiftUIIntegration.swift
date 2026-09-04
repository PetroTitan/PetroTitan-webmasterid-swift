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

    /*
     * ═══════════════════════════════════════════════════════════════════════
     * TWO SPELLINGS OF `onChange`, BECAUSE THE PACKAGE SUPPORTS iOS 15
     * ═══════════════════════════════════════════════════════════════════════
     *
     * `onChange(of:perform:)` — the single-parameter closure — is deprecated
     * as of iOS 17, and building against the iOS 18.5 SDK turns that
     * deprecation into a warning. With `SWIFT_TREAT_WARNINGS_AS_ERRORS` it is
     * an error, which is how CI found it: the SDK's own iOS build passed and
     * this example's did not, because only this file uses SwiftUI.
     *
     * The fix is not to silence the warning. This package declares iOS 15, so
     * BOTH spellings are needed — the modern two-parameter form where it
     * exists, the original where it does not. Dropping the old branch would
     * quietly raise the example's minimum above the SDK's.
     */
    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
            content.onChange(of: scenePhase) { _, phase in
                handle(phase)
            }
        } else {
            content.onChange(of: scenePhase) { phase in
                handle(phase)
            }
        }
    }

    /// The app boundary: a lifecycle hook cannot throw, so it decides here.
    /// See `AnalyticsFailure`.
    private func handle(_ phase: ScenePhase) {
        Task {
            switch phase {
            case .active:
                do { try await lifecycle.openedApp() }
                catch { AnalyticsFailure.report(error, from: "scenePhase.active") }
            case .background:
                await lifecycle.enteredBackground()
            default:
                break
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
