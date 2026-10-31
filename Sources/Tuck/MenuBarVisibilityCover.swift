import AppKit
import ScreenCaptureKit

/// Freezes only the menu-bar strip while a Clock handoff exposes native items.
/// Images live in memory for this transition and never enter the icon cache.
@MainActor
final class MenuBarVisibilityCover {
    private var windows: [NSPanel] = []
    private var timeout: Task<Void, Never>?
    private var generation = 0

    func show() async throws -> Bool {
        hide()
        guard #available(macOS 14.2, *), CGPreflightScreenCaptureAccess() else { return false }
        let revision = generation
        let screens = NSScreen.screens
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        var captured: [(NSRect, NSImage)] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                               width: screen.frame.width, height: height)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            filter.includeMenuBar = true
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: display.frame.width, height: height)
            config.width = Int(display.frame.width * screen.backingScaleFactor)
            config.height = Int(height * screen.backingScaleFactor)
            config.showsCursor = false
            config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            guard generation == revision else { return false }
            captured.append((frame, NSImage(cgImage: image, size: frame.size)))
        }
        guard !captured.isEmpty, generation == revision else { return false }
        for (frame, image) in captured {
            let panel = MenuBarCoverPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Tuck menu bar transition"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = true
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.setAccessibilityElement(false)
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        // A cancelled or failed handoff must never leave a frozen menu bar.
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.generation == revision else { return }
            self.hide()
        }
        return true
    }

    func hide() {
        generation += 1
        timeout?.cancel(); timeout = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
    }
}

private final class MenuBarCoverPanel: NSPanel {
    // Standard window constraints inset a menu-bar-sized panel and shrink its
    // content, visibly rescaling the frozen icons during the handoff.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
