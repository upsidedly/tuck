import AppKit
import SwiftUI
import TuckCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: TuckModel
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { model.toggle() } label: {
                    Label(model.isRevealed ? "Close Pocket" : "Open Pocket", systemImage: model.isRevealed ? "chevron.down" : "chevron.left")
                }
                .disabled(model.hiddenCount == 0 || !model.isSupported)
                .accessibilityIdentifier("toggle-pocket")
                if model.isApplying || model.isCapturingIcons { ProgressView().controlSize(.mini) }
                Spacer()
                if model.previousLayout != nil {
                    Button { model.undoLayoutChange() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo move (⌘Z)").accessibilityLabel("Undo move")
                }
                Button { model.refreshMenuApps(); model.refreshMenuGlyphs(force: true) } label: {
                    if model.isReadingMenu { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(model.isReadingMenu || model.isCapturingIcons)
                .help("Refresh menu icons").accessibilityLabel("Refresh menu icons")
                addApps
            }

            Text("Drag icons between rows.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(IconVisibility.allCases, id: \.self) { rule in
                LayoutGroup(model: model, rule: rule, selectedID: $selectedID)
            }

            Group {
              if let app = model.layoutApps.first(where: { $0.id == selectedID }) {
                HStack {
                    Text(model.menuLabel(for: app)).lineLimit(1).help(model.menuHelp(for: app))
                    Spacer()
                    Picker("Visibility for \(model.menuLabel(for: app))", selection: Binding(get: { app.visibility }, set: { model.move(app, to: $0) })) {
                        ForEach(IconVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("visibility.\(app.id)")
                    if model.apps.contains(where: { $0.id == app.id }) {
                        Button { model.remove(id: app.id); selectedID = nil } label: { Image(systemName: "minus") }
                            .help("Remove saved rule").accessibilityLabel("Remove saved rule for \(model.menuLabel(for: app))")
                    }
                }.font(.system(size: 12))
              } else { Color.clear.accessibilityHidden(true) }
            }.frame(height: 24)

            if !model.hasAccessibility {
                HStack {
                    Text("Allow Accessibility to find and open menu icons.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { model.requestAccessibility() }
                        .accessibilityIdentifier("allow-accessibility")
                }
            } else if model.menuReadFailed && model.layoutApps.isEmpty {
                Text("No menu icons found. Refresh or add an app with +.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !model.hasScreenRecording {
                HStack {
                    Text("Allow Screen Recording for real menu icons.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { model.requestMenuImages() }
                        .accessibilityIdentifier("allow-menu-images")
                }
            }
            Divider()
            HStack {
                Text("Pocket")
                Picker("Pocket style", selection: Binding(get: { model.pocketStyle }, set: { model.setPocketStyle($0) })) {
                    ForEach(PocketStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("pocket-style")
                Spacer()
                Text("⌃⌥B").foregroundStyle(.secondary).help("Open or close Pocket")
            }
            HStack {
                Text("Close Pocket")
                Picker("Close Pocket after", selection: Binding(get: { model.delay }, set: { model.setDelay($0) })) {
                    ForEach(AutoHideDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("auto-hide-delay")
                Spacer()
            }
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).accessibilityIdentifier("quit-tuck")
            }
            if !model.isSupported { Text("Menu bar controls need macOS 27.").foregroundStyle(.secondary) }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("error-message")
                Button("Try Again") { model.retry() }
            }
            if !model.shortcutAvailable {
                Text("⌃⌥B is in use. Click Tuck to open Pocket.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12)).controlSize(.small).tint(.primary)
        .padding(16).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
    }

    private var addApps: some View {
        Menu {
            Section("Running Apps") {
                ForEach(model.runningApps, id: \.processIdentifier) { app in
                    if let url = app.bundleURL {
                        Button(app.localizedName ?? url.deletingPathExtension().lastPathComponent) { model.add(url: url) }
                    }
                }
            }
            Divider()
            Button("Choose App…") { model.chooseApp() }
        } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Add an app").accessibilityLabel("Add an app").accessibilityIdentifier("add-app")
    }
}

private struct LayoutGroup: View {
    @Bindable var model: TuckModel
    let rule: IconVisibility
    @Binding var selectedID: String?
    @State private var targeted = false

    private var apps: [TuckedApp] { model.layoutApps.filter { $0.visibility == rule } }
    var body: some View {
        HStack(spacing: 12) {
            Text(rule.title).font(.system(size: 12, weight: .medium))
                .frame(width: 92, alignment: .leading)
            ScrollView(.horizontal) {
                if apps.isEmpty {
                    Text("Drop icons here").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(minWidth: 300, minHeight: 28, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        ForEach(apps) { app in
                            icon(app)
                        }
                    }
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.45), lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: $targeted) { accept($0) }
            .accessibilityIdentifier("layout.\(rule.rawValue)")
        }
    }

    private func icon(_ app: TuckedApp) -> some View {
        Button { selectedID = app.id } label: {
            MenuItemArtwork(app: app, size: 20, image: model.menuImage(for: app))
                .frame(width: 28, height: 28)
                .background(selectedID == app.id ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(model.menuHelp(for: app))
        .accessibilityLabel(model.menuLabel(for: app)).accessibilityValue(rule.title)
        .accessibilityHint((model.menuLabel(for: app) == app.name ? "" : "Owned by \(app.name). ") + "Drag to another row, or select to change visibility.")
        .accessibilityIdentifier("layout-app.\(app.id)")
        .onDrag {
            NSItemProvider(object: app.id as NSString)
        } preview: {
            MenuItemArtwork(app: app, size: 28, image: model.menuImage(for: app))
        }
        .onDrop(of: [.text], isTargeted: nil) { accept($0, before: app.id) }
        .contextMenu {
            ForEach(IconVisibility.allCases, id: \.self) { destination in
                Button { model.move(app, to: destination) } label: {
                    if destination == rule { Label(destination.title, systemImage: "checkmark") }
                    else { Text(destination.title) }
                }
            }
        }
        .accessibilityAction(named: "Always Show") { model.move(app, to: .show) }
        .accessibilityAction(named: "Show in Bar") { model.move(app, to: .hide) }
        .accessibilityAction(named: "Never Show") { model.move(app, to: .neverShow) }
    }

    private func accept(_ providers: [NSItemProvider], before target: String? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let id = value as? String else { return }
            Task { @MainActor in
                guard id != target, model.move(id: id, to: rule, before: target) else { return }
                selectedID = id
            }
        }
        return true
    }
}
