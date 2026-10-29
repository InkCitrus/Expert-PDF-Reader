import AppKit
import SwiftUI

// MARK: - DetachedReaderWindowController

@MainActor
final class DetachedReaderWindowController: NSObject, NSWindowDelegate {
    let session: ReaderWindowSession
    let window: NSWindow
    weak var store: AppStore?
    /// Set when the window is closed programmatically because its tabs were merged into another window or on app quit
    var suppressCloseRecording = false

    init(
        store: AppStore,
        session: ReaderWindowSession,
        sourceWindow: NSWindow?,
        screenDropPoint: NSPoint?
    ) {
        self.store = store
        self.session = session

        let baseSize = sourceWindow?.frame.size ?? NSSize(width: 1180, height: 780)
        let targetScreen = Self.screen(containing: screenDropPoint)
            ?? sourceWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1440, height: 900)
        let width = min(max(600, baseSize.width), visibleFrame.width)
        let height = min(max(520, baseSize.height), visibleFrame.height)

        let origin: NSPoint
        if let drop = screenDropPoint {
            // Place the detached window's unified 40pt tab strip right under the cursor
            let unclampedX = drop.x - min(180, width * 0.25)
            let unclampedY = drop.y - height + MainWindowView.tabStripHeight * 0.5
            origin = NSPoint(
                x: min(max(visibleFrame.minX, unclampedX), visibleFrame.maxX - width),
                y: min(max(visibleFrame.minY, unclampedY), visibleFrame.maxY - height)
            )
        } else if let srcFrame = sourceWindow?.frame {
            // Cascade slightly down-right like Safari & Finder
            let cascadedX = srcFrame.origin.x + 28
            let cascadedY = srcFrame.origin.y - 28
            origin = NSPoint(
                x: min(max(visibleFrame.minX, cascadedX), visibleFrame.maxX - width),
                y: min(max(visibleFrame.minY, cascadedY), visibleFrame.maxY - height)
            )
        } else {
            origin = NSPoint(
                x: visibleFrame.midX - width * 0.5,
                y: visibleFrame.midY - height * 0.5
            )
        }

        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        window.makeKeyAndOrderFront(nil)
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

// MARK: - Floating Screen-Wide Tab Tear-Off Preview Panel

@MainActor
final class TabDragPreviewController {
    static let shared = TabDragPreviewController()

    enum ActionStyle: Equatable {
        case detachToNewWindow
        case mergeIntoWindow
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<TabTearOffBadgeView>?
    private var lastModel: Model?

    private struct Model: Equatable {
        let title: String
        let style: ActionStyle
        let isDark: Bool
    }

    func update(at screenPoint: NSPoint, title: String, style: ActionStyle, isDark: Bool) {
        let model = Model(title: title, style: style, isDark: isDark)
        let panel = ensurePanel(for: model)
        if lastModel != model {
            hostingView?.rootView = TabTearOffBadgeView(title: title, style: style, isDark: isDark)
            hostingView?.layoutSubtreeIfNeeded()
            if let fitting = hostingView?.fittingSize, fitting.width > 0, fitting.height > 0 {
                panel.setContentSize(fitting)
            }
            lastModel = model
        }

        let size = panel.frame.size
        let origin = NSPoint(
            x: (screenPoint.x - size.width * 0.5).rounded(),
            y: (screenPoint.y - size.height - 14).rounded()
        )
        panel.setFrameOrigin(origin)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        lastModel = nil
    }

    private func ensurePanel(for model: Model) -> NSPanel {
        if let existing = panel {
            return existing
        }
        let view = TabTearOffBadgeView(title: model.title, style: model.style, isDark: model.isDark)
        let host = NSHostingView(rootView: view)
        let fitting = host.fittingSize
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: max(180, fitting.width), height: max(46, fitting.height))),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        self.hostingView = host
        self.panel = p
        return p
    }
}

private struct TabTearOffBadgeView: View {
    let title: String
    let style: TabDragPreviewController.ActionStyle
    let isDark: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppPalette.accentBlue.opacity(isDark ? 0.24 : 0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: style == .mergeIntoWindow ? "arrow.down.right.and.arrow.up.left" : "macwindow.badge.plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(AppPalette.accentBlue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .lineLimit(1)
                    .frame(maxWidth: 210, alignment: .leading)

                Text(
                    style == .mergeIntoWindow
                        ? L10n.tr("松开以合并到此窗口", "Release to Merge into Window")
                        : L10n.tr("松开以在新窗口打开", "Release to Open in New Window")
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(AppPalette.accentBlue)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppPalette.floatingTooltipBackground(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppPalette.accentBlue.opacity(0.65), lineWidth: 1.2)
        )
    }
}
