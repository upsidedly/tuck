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
                .disabled(model.hiddenCount == 0 || !model.isSupported || model.isReordering)
                .accessibilityIdentifier("toggle-pocket")
                if model.isApplying || model.isCapturingIcons || model.isReordering { ProgressView().controlSize(.mini) }
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

            Text("Drag to arrange icons.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(IconVisibility.allCases, id: \.self) { rule in
                LayoutGroup(model: model, rule: rule, selectedID: $selectedID)
            }

            Group {
              if let app = model.layoutApps.first(where: { $0.id == selectedID }) {
                HStack {
                    Text(model.menuLabel(for: app)).lineLimit(1).help(model.menuHelp(for: app))
                    Spacer()
                    Button { model.shift(id: app.id, by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canShift(id: app.id, by: -1))
                        .help("Move left").accessibilityLabel("Move left").accessibilityIdentifier("layout-move-left")
                    Button { model.shift(id: app.id, by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.canShift(id: app.id, by: 1))
                        .help("Move right").accessibilityLabel("Move right").accessibilityIdentifier("layout-move-right")
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
    @State private var insertion: LayoutInsertion?

    private var ids: [String] { model.layoutIDs(for: rule) }
    var body: some View {
        HStack(spacing: 12) {
            Text(rule.title).font(.system(size: 12, weight: .medium))
                .frame(width: 92, alignment: .leading)
            ScrollView(.horizontal) {
                if ids.isEmpty {
                    Text("Drop icons here").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(minWidth: 300, minHeight: 28, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        ForEach(ids, id: \.self) { id in
                            tile(id)
                        }
                    }
                    .frame(minWidth: 300, alignment: .leading)
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if insertion != nil { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: LayoutDropDelegate(leading: .end, trailing: nil,
                insertion: $insertion, accept: accept))
            .accessibilityIdentifier("layout.\(rule.rawValue)")
        }
    }

    @ViewBuilder private func tile(_ id: String) -> some View {
        let following = ids.firstIndex(of: id).flatMap { index in
            ids.indices.contains(index + 1) ? ids[index + 1] : nil
        }
        Group {
            if id == TuckModel.host {
                Image(systemName: model.isRevealed ? "chevron.down" : "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    .help("Tuck · Drag icons before or after this fixed caret.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tuck caret")
                    .accessibilityValue("Always Show, fixed")
                    .accessibilityHint("Drag icons before or after Tuck. The caret cannot be moved.")
                    .accessibilityIdentifier("layout-tuck-anchor")
            } else if let app = model.layoutApps.first(where: { $0.id == id }) {
                icon(app)
            }
        }
        .overlay(alignment: .leading) {
            if insertion == LayoutInsertion(before: id) { insertionLine.offset(x: -4) }
        }
        .overlay(alignment: .trailing) {
            if following == nil, insertion == .end { insertionLine.offset(x: 4) }
        }
        .onDrop(of: [.text], delegate: LayoutDropDelegate(leading: LayoutInsertion(before: id),
            trailing: LayoutInsertion(before: following), insertion: $insertion, accept: accept))
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1).fill(.primary).frame(width: 2, height: 22)
            .allowsHitTesting(false).accessibilityHidden(true)
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
        .accessibilityHint((model.menuLabel(for: app) == app.name ? "" : "Owned by \(app.name). ") + "Drag to arrange or change rows. Select for move controls.")
        .accessibilityIdentifier("layout-app.\(app.id)")
        .onDrag {
            selectedID = app.id
            return NSItemProvider(object: app.id as NSString)
        } preview: {
            MenuItemArtwork(app: app, size: 28, image: model.menuImage(for: app))
        }
        .contextMenu {
            Button("Move Left") { model.shift(id: app.id, by: -1) }
                .disabled(!model.canShift(id: app.id, by: -1))
            Button("Move Right") { model.shift(id: app.id, by: 1) }
                .disabled(!model.canShift(id: app.id, by: 1))
            Divider()
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
        .accessibilityAction(named: "Move left") { model.shift(id: app.id, by: -1) }
        .accessibilityAction(named: "Move right") { model.shift(id: app.id, by: 1) }
    }

    private func accept(_ providers: [NSItemProvider], _ target: String?) -> Bool {
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

private struct LayoutInsertion: Equatable {
    let before: String?
    static let end = LayoutInsertion(before: nil)
}

private struct LayoutDropDelegate: DropDelegate {
    let leading: LayoutInsertion
    let trailing: LayoutInsertion?
    @Binding var insertion: LayoutInsertion?
    let accept: ([NSItemProvider], String?) -> Bool

    private func destination(_ info: DropInfo) -> LayoutInsertion {
        if let trailing, info.location.x >= 14 { return trailing }
        return leading
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { insertion = destination(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertion = destination(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if insertion == leading || insertion == trailing { insertion = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        let target = destination(info)
        insertion = nil
        return accept(info.itemProviders(for: [.text]), target.before)
    }
}
