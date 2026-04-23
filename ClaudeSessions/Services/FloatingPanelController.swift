import AppKit
import SwiftUI

/// Owns the always-on-top floating panels — a full 500x500 session view
/// panel and a compact pill panel. They're two separate fixed-size
/// NSPanels rather than one resizable panel: any size transition on a
/// single SwiftUI-hosted window tripped NSHostingView's updateConstraints
/// pass into a loop (NSGenericException). Two fixed panels, flipped by
/// hide/show, sidestep that entirely.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingPanelController()

    private var mainPanel: NSPanel?
    private var pillPanel: NSPanel?
    private var mainController: NSHostingController<FloatingPanelContent>?
    private var pillController: NSHostingController<CompactPillView>?
    private weak var boundStore: SessionStore?

    /// Injected from the `App` scene context so "Open History" from a row
    /// inside the panel routes through the same `WindowGroup("history")`
    /// the popover uses.
    private var openHistoryAction: ((String) -> Void)?

    static let mainSize = NSSize(width: 500, height: 500)
    static let pillSize = NSSize(width: 260, height: 44)
    private static let mainOriginKey = "floatingPanelOrigin.v1"
    private static let pillOriginKey = "floatingPanelPillOrigin.v1"

    private override init() { super.init() }

    func setOpenHistory(_ action: @escaping (String) -> Void) {
        openHistoryAction = action
    }

    // MARK: - Show/hide

    func toggle(store: SessionStore) {
        if isAnyVisible {
            hide()
        } else {
            show(store: store)
        }
    }

    func show(store: SessionStore) {
        boundStore = store
        if store.isFloatingPanelCompact {
            showPill(store: store)
        } else {
            showMain(store: store)
        }
        store.isFloatingPanelOpen = true
    }

    func hide() {
        mainPanel?.orderOut(nil)
        pillPanel?.orderOut(nil)
        boundStore?.isFloatingPanelOpen = false
    }

    func restoreOnLaunchIfNeeded(store: SessionStore) {
        if store.isFloatingPanelOpen { show(store: store) }
    }

    /// Collapse main → pill. Hides the main panel and shows the pill at
    /// its last-known position.
    func minimizeToPill() {
        guard let store = boundStore else { return }
        mainPanel?.orderOut(nil)
        showPill(store: store)
        store.isFloatingPanelCompact = true
    }

    /// Expand pill → main. Inverse of `minimizeToPill`.
    func expandToMain() {
        guard let store = boundStore else { return }
        pillPanel?.orderOut(nil)
        showMain(store: store)
        store.isFloatingPanelCompact = false
    }

    /// Force-surfaces the main panel. Used when a permission request comes
    /// in — the user needs to see and act on the card, so we bring the
    /// full 500x500 panel forward even if they were currently hidden or
    /// minimized to the pill.
    func surfaceMainForAttention(store: SessionStore) {
        boundStore = store
        pillPanel?.orderOut(nil)
        showMain(store: store)
        store.isFloatingPanelOpen = true
        store.isFloatingPanelCompact = false
    }

    private var isAnyVisible: Bool {
        (mainPanel?.isVisible == true) || (pillPanel?.isVisible == true)
    }

    private func showMain(store: SessionStore) {
        let panel = ensureMainPanel(store: store)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    private func showPill(store: SessionStore) {
        let panel = ensurePillPanel(store: store)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // If either panel closes by user gesture, reflect that in the store.
        boundStore?.isFloatingPanelOpen = false
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainPanel {
            saveOrigin(window.frame.origin, key: Self.mainOriginKey)
        } else if window === pillPanel {
            saveOrigin(window.frame.origin, key: Self.pillOriginKey)
        }
    }

    // MARK: - Panel creation

    private func ensureMainPanel(store: SessionStore) -> NSPanel {
        if let mainPanel { return mainPanel }

        let content = FloatingPanelContent(
            store: store,
            openHistory: { [weak self] id in self?.openHistoryAction?(id) },
            onMinimize: { [weak self] in self?.minimizeToPill() },
            onClose: { [weak self] in self?.hide() }
        )
        let controller = NSHostingController(rootView: content)
        controller.preferredContentSize = Self.mainSize
        if #available(macOS 13.0, *) {
            controller.sizingOptions = []
        }
        mainController = controller

        let panel = makeFloatingPanel(size: Self.mainSize, originKey: Self.mainOriginKey)
        panel.contentViewController = controller
        panel.setContentSize(Self.mainSize)
        mainPanel = panel
        return panel
    }

    private func ensurePillPanel(store: SessionStore) -> NSPanel {
        if let pillPanel { return pillPanel }

        let content = CompactPillView(
            store: store,
            onExpand: { [weak self] in self?.expandToMain() }
        )
        let controller = NSHostingController(rootView: content)
        controller.preferredContentSize = Self.pillSize
        if #available(macOS 13.0, *) {
            controller.sizingOptions = []
        }
        pillController = controller

        let panel = makeFloatingPanel(size: Self.pillSize, originKey: Self.pillOriginKey)
        panel.contentViewController = controller
        panel.setContentSize(Self.pillSize)
        pillPanel = panel
        return panel
    }

    private func makeFloatingPanel(size: NSSize, originKey: String) -> NSPanel {
        let origin = loadOrigin(key: originKey) ?? defaultOrigin(for: size)
        let frame = NSRect(origin: origin, size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        // `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually
        // exclusive — AppKit asserts on the combination. We want the
        // panel visible on every Space simultaneously, which is
        // `.canJoinAllSpaces`.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // Transparent window + opaque rounded content means the shadow
        // tracks the rounded shape instead of the square window frame.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        return panel
    }

    // MARK: - Origin persistence

    private func saveOrigin(_ origin: NSPoint, key: String) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: key)
    }

    private func loadOrigin(key: String) -> NSPoint? {
        guard let str = UserDefaults.standard.string(forKey: key) else { return nil }
        let point = NSPointFromString(str)
        // Whether the resulting rect still overlaps an attached screen —
        // guards against a monitor unplug between runs.
        return point
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.maxX - size.width - 24
        let y = screen.maxY - size.height - 24
        return NSPoint(x: x, y: y)
    }
}
