import AppKit
import SwiftUI
import TuckCore

@MainActor
final class PocketController {
    private let model: TuckModel
    private let anchor: () -> NSRect?
    private var panel: PocketPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appliedStyle: PocketStyle?

    init(model: TuckModel, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
    }

    var containsPointer: Bool { panel?.isVisible == true && panel?.frame.contains(NSEvent.mouseLocation) == true }

    func synchronize() {
        guard model.isRevealed, !model.pocketApps.isEmpty else { close(); return }
        if panel == nil {
            let window = PocketPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.setAccessibilityTitle("Pocket")
            window.title = "Pocket"
            panel = window
        }
        guard let panel else { return }
        if appliedStyle != model.pocketStyle || panel.contentView == nil {
            let content = NSHostingView(rootView: PocketView(model: model))
            if model.pocketStyle == .liquidGlass, #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = 12
                glass.contentView = content
                panel.contentView = glass
                panel.appearance = nil
            } else {
                panel.contentView = content
                panel.appearance = NSAppearance(named: .darkAqua)
            }
            appliedStyle = model.pocketStyle
        }
        let rect = anchor()
        let screen = NSScreen.screens.first { screen in rect.map { screen.frame.intersects($0) } ?? false }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let contentWidth: CGFloat
        if model.isCapturingIcons { contentWidth = 140 }
        else { contentWidth = model.pocketItems.reduce(12) { $0 + $1.width + 4 } }
        let width = min(contentWidth, screen.visibleFrame.width - 24)
        let x = min(max((rect?.midX ?? screen.visibleFrame.maxX - 80) - width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
        panel.setFrame(NSRect(x: x, y: top - 48, width: width, height: 42), display: true)
        if panel.isVisible { panel.orderFrontRegardless() }
        else { panel.makeKeyAndOrderFront(nil) }
        installMonitors()
    }

    func close() {
        panel?.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
    }

    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { model.hide() }
            return
        }
        let point = NSEvent.mouseLocation
        guard panel?.frame.contains(point) != true, anchor()?.contains(point) != true else { return }
        model.hide()
    }
}

private final class PocketPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PocketView: View {
    @Bindable var model: TuckModel
    @State private var hoveredID: String?

    var body: some View {
        Group {
            if model.isCapturingIcons {
                ProgressView().controlSize(.small).accessibilityLabel("Loading menu icons")
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.pocketItems) { item in
                            Button { model.openMenu(for: item.app, label: item.glyph?.label) } label: { icon(item) }
                                .buttonStyle(.plain)
                                .disabled(!model.isRunning(item.app) || model.isApplying)
                                .help(model.isRunning(item.app) ? model.menuHelp(for: item.app) : "\(model.menuLabel(for: item.app)) is not running")
                                .accessibilityLabel("Open \(model.menuLabel(for: item.app))’s menu")
                                .accessibilityIdentifier("pocket.\(item.app.id)")
                                .onHover { hoveredID = $0 ? item.id : nil }
                        }
                    }.padding(6)
                }.scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .background {
            if model.pocketStyle == .black { RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.08)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityLabel("Pocket")
    }

    private func icon(_ item: PocketItem) -> some View {
        Group {
            if let image = item.image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: min(image.size.width, 160), height: min(image.size.height, 22))
            } else {
                MenuItemArtwork(app: item.app, size: 20)
            }
        }
        .frame(width: item.width, height: 30)
        .background(hoveredID == item.id ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
