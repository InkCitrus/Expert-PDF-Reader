import AppKit
import SwiftUI

// MARK: - DetachedReaderWindowController

@MainActor
final class DetachedReaderWindowController: NSObject, NSWindowDelegate {
    let session: ReaderWindowSession
    let window: NSWindow
    weak var store: AppStore?
    private let screenDropPoint: NSPoint?
    private let tabGrabOffset: NSPoint?
    /// Set when the window is closed programmatically because its tabs were merged into another window or on app quit
    var suppressCloseRecording = false

    init(
        store: AppStore,
        session: ReaderWindowSession,
        sourceWindow: NSWindow?,
        screenDropPoint: NSPoint?,
        tabGrabOffset: NSPoint? = nil
    ) {
        self.store = store
        self.session = session
        self.screenDropPoint = screenDropPoint
        self.tabGrabOffset = tabGrabOffset

        let baseSize = sourceWindow?.frame.size ?? NSSize(width: 1180, height: 780)
        let targetScreen = Self.screen(containing: screenDropPoint)
            ?? sourceWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1440, height: 900)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
        let width = min(max(600, baseSize.width), visibleFrame.width)
        let height = min(max(520, baseSize.height), visibleFrame.height - titlebarHeight)

        let origin: NSPoint
        if let drop = screenDropPoint {
            // Keep the unified titlebar under the same cursor position when tearing off a tab.
            let unclampedX = drop.x - min(180, width * 0.25)
            let unclampedY = drop.y - height + MainWindowView.tabStripHeight * 0.5
            origin = NSPoint(
                x: min(max(visibleFrame.minX, unclampedX), visibleFrame.maxX - width),
                y: min(max(visibleFrame.minY, unclampedY), visibleFrame.maxY - height - titlebarHeight)
            )
        } else if let srcFrame = sourceWindow?.frame {
            // Cascade slightly down-right like Safari & Finder
            let cascadedX = srcFrame.origin.x + 28
            let cascadedY = srcFrame.origin.y - 28
            origin = NSPoint(
                x: min(max(visibleFrame.minX, cascadedX), visibleFrame.maxX - width),
                y: min(max(visibleFrame.minY, cascadedY), visibleFrame.maxY - height - titlebarHeight)
            )
        } else {
            origin = NSPoint(
                x: visibleFrame.midX - width * 0.5,
                y: visibleFrame.midY - height * 0.5
            )
        }

        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 520)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .none
        win.isMovableByWindowBackground = false
        self.window = win
        super.init()

        session.nsWindow = win
        win.delegate = self
        win.contentView = NSHostingView(rootView: MainWindowView(store: store, session: session))
    }

    func showWindow() {
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate { window.alphaValue = 0 }
        window.makeKeyAndOrderFront(nil)
        if let screenDropPoint, let tabGrabOffset, let tabID = session.activeDocumentTab?.id {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            session.positionWindowForTabDrop(tabID: tabID, grabOffset: tabGrabOffset, at: screenDropPoint)
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                window.animator().alphaValue = 1
            }
        }
    }

    func closeProgrammatically() {
        suppressCloseRecording = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.handleDetachedWindowWillClose(
                sessionID: session.id,
                recordClosedTabs: !suppressCloseRecording
            )
        }
    }

    private static func screen(containing point: NSPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
