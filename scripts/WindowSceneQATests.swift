import AppKit
import SwiftUI

/// Exercise a real SwiftUI scene: a plain NSWindow does not catch SwiftUI resetting titlebar configuration.
@main struct WindowSceneQA: App {
    @StateObject private var store = AppStore()
    @State private var scheme: ColorScheme = .dark

    var body: some Scene {
        Window("Window Scene QA", id: "scene-qa") {
            MainWindowView(store: store)
                .preferredColorScheme(scheme)
                .task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    var failures = check(.dark)
                    scheme = .light
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    failures += check(.light)
                    fflush(stdout)
                    exit(failures == 0 ? 0 : 1)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1000, height: 700)
    }

    @MainActor private func check(_ scheme: ColorScheme) -> Int {
        guard let window = store.primarySession.nsWindow, let strip = store.primarySession.tabStripView else {
            print("FAIL scene has an attached native tab strip")
            return 1
        }
        let rect = window.convertToScreen(strip.convert(strip.bounds, to: nil))
        let checks = [
            (abs(rect.height - MainWindowView.tabStripHeight) < 1, "\(scheme) titlebar retains the original 40pt height"),
            (window.titlebarAppearsTransparent, "\(scheme) native button area uses the tab strip background"),
            (abs(rect.maxY - window.frame.maxY) < 1, "\(scheme) tabs share one row with the native controls"),
            (window.toolbar?.isVisible == true, "\(scheme) SwiftUI keeps the compact toolbar visible")
        ]
        for (passed, message) in checks { print("\(passed ? "PASS" : "FAIL") \(message)") }
        return checks.filter { !$0.0 }.count
    }
}
