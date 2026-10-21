import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = TuckModel()
    private var statusItem: NSStatusItem?
    private var settings: NSWindow?
    private var pocket: PocketController?
    private var lastRevealed: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: TuckModel.host)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Tuck"
        item.isVisible = true
        item.behavior = []
        item.button?.setAccessibilityIdentifier("tuck-menu-bar")
        item.button?.target = self
        item.button?.action = #selector(statusItemPressed)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show menu", target: self, selector: #selector(accessibilityShowMenu))
        ])
        statusItem = item
        pocket = PocketController(model: model) { [weak self] in self?.statusItemFrame }
        model.isPointerInPocket = { [weak self] in self?.pocket?.containsPointer == true }
        model.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.pocket?.synchronize()
            self?.resizeSettings()
        }
        model.onRequestSettings = { [weak self] in self?.showSettings() }
        model.start()
        updateStatusItem()
        installApplicationMenu()
        if !model.hasAccessibility { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { pocket?.close(); model.stop() }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshMenuApps() }

    private var statusItemFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func showSettings() {
        if settings == nil {
            let panel = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "Tuck"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            panel.setContentSize(panel.contentViewController?.view.fittingSize ?? NSSize(width: 280, height: 280))
            settings = panel
        }
        model.settingsOpen = true
        model.refreshMenuApps()
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
        resizeSettings(center: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.settingsOpen = false
        model.scheduleAutoHide()
    }

    private func resizeSettings(center: Bool = false) {
        guard settings != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.settings, let view = panel.contentViewController?.view else { return }
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0 && size.height > 0 {
                let top = panel.frame.maxY
                panel.setContentSize(size)
                if center, let screen = panel.screen ?? NSScreen.main {
                    let visible = screen.visibleFrame
                    panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                                 y: visible.midY - panel.frame.height / 2))
                } else {
                    panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: model.isRevealed ? "Close Pocket" : "Open Pocket", action: #selector(toggleIcons), keyEquivalent: "b")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        toggle.isEnabled = model.hiddenCount > 0 && model.isSupported
        menu.addItem(toggle)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tuck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) { model.settingsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        model.settingsOpen = settings?.isVisible == true
        model.scheduleAutoHide()
    }

    private func updateStatusItem() {
        let button = statusItem?.button
        if lastRevealed != model.isRevealed {
            button?.image = TuckIcon.caretImage(pocketOpen: model.isRevealed)
            lastRevealed = model.isRevealed
        }
        button?.toolTip = "Tuck · Click for Pocket · Right-click for Settings · ⌃⌥B"
        button?.setAccessibilityLabel("Tuck")
        button?.setAccessibilityValue(model.isRevealed ? "Pocket open" : "Pocket closed")
    }
    @objc private func statusItemPressed() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu() }
        else { model.toggle() }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu(title: "Tuck")
        menu.autoenablesItems = false
        menu.delegate = self
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4), in: button)
    }

    @objc private func accessibilityShowMenu() -> Bool {
        showStatusMenu()
        return true
    }

    @objc private func toggleIcons() { model.toggle() }
    @objc private func closeSettings() { settings?.performClose(nil) }
    @objc private func undoMove() { model.undoLayoutChange() }

    private func installApplicationMenu() {
        let main = NSMenu()
        let root = NSMenuItem()
        let app = NSMenu(title: "Tuck")
        let toggle = NSMenuItem(title: "Open or Close Pocket", action: #selector(toggleIcons), keyEquivalent: "b")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        app.addItem(toggle)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        app.addItem(preferences)
        let close = NSMenuItem(title: "Close Settings", action: #selector(closeSettings), keyEquivalent: "w")
        close.target = self
        app.addItem(close)
        let undo = NSMenuItem(title: "Undo Move", action: #selector(undoMove), keyEquivalent: "z")
        undo.target = self
        app.addItem(undo)
        app.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tuck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        app.addItem(quit)
        root.submenu = app
        main.addItem(root)
        NSApp.mainMenu = main
    }
}

@main
enum TuckApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
