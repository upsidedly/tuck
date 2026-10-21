import AppKit
import ApplicationServices
import Observation
import NativeVisibility
import ServiceManagement
import TuckCore
import UniformTypeIdentifiers

@MainActor @Observable
final class TuckModel {
    static let host = "dev.matthew.tuck"
    private(set) var apps: [TuckedApp]
    private(set) var delay: AutoHideDelay
    private(set) var pocketStyle: PocketStyle
    private(set) var isRevealed = false
    private(set) var isApplying = false
    private(set) var shortcutAvailable = false
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var hasAccessibility = AXIsProcessTrusted()
    private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()
    private(set) var isCapturingIcons = false
    private(set) var glyphRecords: [MenuGlyphRecord] = []
    private(set) var glyphImages: [String: NSImage] = [:]
    private(set) var detectedApps: [TuckedApp] = []
    private(set) var menuIcons: [MenuIcon] = []
    private(set) var isReadingMenu = false
    private(set) var menuReadFailed = false
    private(set) var previousLayout: [TuckedApp]?
    private var visibilityError: String?
    private var actionError: String?
    private var iconCaptureError: String?
    var settingsOpen = false
    var onChange: (() -> Void)?
    var onRequestSettings: (() -> Void)?
    var isPointerInPocket: (() -> Bool)?

    @ObservationIgnored private let session = TKVisibilitySession()
    @ObservationIgnored private let catalog = MenuCatalog()
    @ObservationIgnored private let glyphStore = MenuGlyphStore()
    @ObservationIgnored private let menuTracker = NativeMenuTracker()
    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    @ObservationIgnored private var glyphTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var glyphGeneration = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var actionGeneration = 0
    @ObservationIgnored private var temporaryApp: String?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults: UserDefaults

    var pocketApps: [TuckedApp] { VisibilityPolicy.pocketApps(apps, host: Self.host) }
    var hiddenCount: Int { pocketApps.count }
    var managedCount: Int { apps.filter { $0.visibility != .show }.count }
    var isSupported: Bool { session.isSupported }
    var errorMessage: String? { visibilityError ?? actionError ?? iconCaptureError }
    var layoutApps: [TuckedApp] { VisibilityPolicy.normalized(apps + detectedApps, host: Self.host) }
    var needsMenuImages: Bool { pocketApps.contains { app in !glyphRecords.contains { $0.owner == app.id && glyphImages[$0.key] != nil } } }
    var pocketItems: [PocketItem] {
        pocketApps.flatMap { app -> [PocketItem] in
            let records = hasScreenRecording ? glyphRecords.filter { $0.owner == app.id && glyphImages[$0.key] != nil } : []
            return records.isEmpty ? [PocketItem(app: app, glyph: nil, image: nil)] : records.map {
                PocketItem(app: app, glyph: $0, image: glyphImages[$0.key])
            }
        }
    }

    func menuImage(for app: TuckedApp) -> NSImage? {
        guard hasScreenRecording, let record = glyphRecords.first(where: { $0.owner == app.id && glyphImages[$0.key] != nil }) else { return nil }
        return glyphImages[record.key]
    }

    func menuLabel(for app: TuckedApp) -> String {
        if app.systemItem != nil { return app.name }
        let liveLabels = entries(for: app).map(\.label)
        let labels = liveLabels.isEmpty ? glyphRecords.filter { $0.owner == app.id }.map(\.label) : liveLabels
        let names = Set(labels.filter { !$0.isEmpty && $0 != "Menu icon" && !$0.hasPrefix("com.") })
        return labels.count == 1 && names.count == 1 ? names.first ?? app.name : app.name
    }

    func menuHelp(for app: TuckedApp) -> String {
        let label = menuLabel(for: app)
        return label == app.name ? label : "\(label) · \(app.name)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: "apps")
        apps = VisibilityPolicy.normalized(data.flatMap { try? JSONDecoder().decode([TuckedApp].self, from: $0) } ?? [], host: Self.host)
        delay = AutoHideDelay(rawValue: defaults.integer(forKey: "autoHideDelay")) ?? .off
        pocketStyle = defaults.string(forKey: "pocketStyle").flatMap(PocketStyle.init(rawValue:)) ?? .black
    }

    func start() {
        hotKey.onPress = { [weak self] in self?.toggle() }
        shortcutAvailable = hotKey.register()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningAppsChanged() }
            })
        }
        if managedCount > 0 { applyNativeVisibility() }
        refreshMenuApps()
        cacheTask = Task { [weak self] in
            guard let self else { return }
            let cached = await self.glyphStore.load()
            guard !Task.isCancelled else { return }
            self.installGlyphs(cached)
            self.onChange?()
            if self.hasScreenRecording { self.refreshMenuGlyphs() }
        }
    }

    func stop() {
        generation += 1; actionGeneration += 1; refreshGeneration += 1; glyphGeneration += 1
        deadline?.cancel(); timer?.cancel(); refreshTask?.cancel(); activationTask?.cancel()
        glyphTask?.cancel(); cacheTask?.cancel()
        menuTracker.stop()
        session.showAll()
        hotKey.unregister()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    func toggle() { isRevealed ? hide() : show() }

    func show() {
        guard hiddenCount > 0, hasAccessibility else { onRequestSettings?(); return }
        isRevealed = true
        onChange?()
        scheduleAutoHide()
        if hasScreenRecording && needsMenuImages { refreshMenuGlyphs() }
    }

    func hide() {
        timer?.cancel(); timer = nil
        isRevealed = false
        onChange?()
    }

    func retry() {
        actionError = nil
        applyNativeVisibility()
        refreshMenuApps()
        refreshMenuGlyphs(force: true)
    }

    // Pocket is a separate bar. Only a menu action or a missing-icon capture
    // temporarily exposes one Show-in-Bar owner in the native bar.
    private func applyNativeVisibility() {
        deadline?.cancel(); deadline = nil
        generation += 1
        let revision = generation
        visibilityError = nil
        if VisibilityPolicy.suppressedItems(apps: apps, host: Self.host, temporarilyVisible: temporaryApp).isEmpty {
            session.showAll()
            isApplying = false
            onChange?()
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let allowed = VisibilityPolicy.allowedBundles(running: running, apps: apps, host: Self.host, temporarilyVisible: temporaryApp)
        let systemItems = VisibilityPolicy.allowedSystemItems(apps: apps, host: Self.host, temporarilyVisible: temporaryApp).map { NSNumber(value: $0) }
        isApplying = true
        onChange?()
        session.showOnlyBundleIdentifiers(allowed, allowedSystemItems: systemItems) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.generation == revision else { return }
                self.deadline?.cancel(); self.deadline = nil
                self.isApplying = false
                self.visibilityError = error?.localizedDescription
                self.onChange?()
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.generation == revision, self.isApplying else { return }
            self.generation += 1
            self.session.cancelPendingChange()
            self.isApplying = false
            self.visibilityError = "The menu bar did not respond. Try again."
            self.onChange?()
        }
    }

    func entries(for app: TuckedApp) -> [MenuIcon] {
        menuIcons.filter { matches($0, app: app) }
    }

    func isRunning(_ app: TuckedApp) -> Bool {
        owner(for: app) != nil
    }

    private func owner(for app: TuckedApp) -> NSRunningApplication? {
        if let system = app.systemItem {
            if let item = menuIcons.first(where: { $0.systemItem == system }),
               let owner = NSRunningApplication(processIdentifier: item.pid) { return owner }
            return app.ownerBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first
    }

    private func matches(_ icon: MenuIcon, app: TuckedApp) -> Bool {
        if let system = app.systemItem { return icon.systemItem == system }
        return icon.ownerBundleID == app.id
    }

    private func readMenuIcons(for app: TuckedApp? = nil) async -> [MenuIcon] {
        let running = NSWorkspace.shared.runningApplications
        let agent = running.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" })?.processIdentifier
        let clients = app.flatMap { owner(for: $0).map { [$0.processIdentifier] } } ?? running.map(\.processIdentifier)
        let owners = Dictionary(uniqueKeysWithValues: running.compactMap { app in app.bundleIdentifier.map { (app.processIdentifier, $0) } })
        return await catalog.read(agentPID: agent, clientPIDs: clients, owners: owners)
    }

    private func relatedMenuOwners(for app: TuckedApp) -> Set<pid_t> {
        let bundles: Set<String>
        switch app.systemItem {
        case .battery, .bluetooth, .displays, .sound, .wifi, .screenMirroring:
            bundles = ["com.apple.controlcenter"]
        case .siri: bundles = ["com.apple.Siri", "com.apple.campo"]
        case .spotlight: bundles = ["com.apple.campo", "com.apple.Spotlight"]
        case .inputSource: bundles = ["com.apple.TextInputMenuAgent"]
        case nil: bundles = []
        }
        return Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map { bundles.contains($0) } == true }.map(\.processIdentifier))
    }

    func openMenu(for app: TuckedApp, iconID: String? = nil, label: String? = nil) {
        guard apps.contains(where: { $0.id == app.id && $0.visibility == .hide }), hasAccessibility,
              !isCapturingIcons,
              let pid = owner(for: app)?.processIdentifier else { return }
        cancelNativeMenu()
        let revision = actionGeneration
        let chosenLabel = label ?? menuIcons.first(where: { $0.id == iconID })?.label
        actionError = nil
        temporaryApp = app.id
        applyNativeVisibility()
        activationTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<100 where self.isApplying {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled, self.actionGeneration == revision else { return }
            guard self.visibilityError == nil, !self.isApplying else { self.finishNativeMenu(); return }
            let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier
            var selected: MenuIcon?
            // Native placement can settle after its assertion callback.
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let icons = await self.readMenuIcons(for: app)
                guard !Task.isCancelled, self.actionGeneration == revision else { return }
                selected = icons.first(where: { self.matches($0, app: app) && ($0.id == iconID || $0.label == chosenLabel) })
                    ?? icons.first(where: { self.matches($0, app: app) })
                if let frame = selected?.frame, frame.width > 0, frame.minX >= 0 { break }
            }
            guard let selected else {
                self.finishNativeMenu()
                self.actionError = "\(app.name)’s menu icon is unavailable. Refresh the layout and try again."
                return
            }
            let related = self.relatedMenuOwners(for: app)
            let baseline = NativeMenuTracker.windows(pid: pid, agentPID: agent, relatedPIDs: related)
            let result = await self.catalog.press(id: selected.id)
            guard !Task.isCancelled, self.actionGeneration == revision else { return }
            // Never press twice after an ambiguous AX result: it could execute
            // a capture or toggle action twice.
            if result != AXError.success.rawValue {
                self.actionError = "Couldn’t open \(app.name)’s menu (\(result))."
            }
            self.hide()
            self.menuTracker.start(pid: pid, agentPID: agent, relatedPIDs: related, baseline: baseline) { [weak self] in
                guard let self, self.actionGeneration == revision else { return }
                self.finishNativeMenu()
            }
        }
    }

    private func cancelNativeMenu() {
        actionGeneration += 1
        activationTask?.cancel(); activationTask = nil
        menuTracker.stop()
        temporaryApp = nil
    }

    private func finishNativeMenu() {
        cancelNativeMenu()
        applyNativeVisibility()
    }

    func move(_ app: TuckedApp, to rule: IconVisibility, before target: String? = nil) {
        guard VisibilityPolicy.canHide(app.id, host: Self.host) else { return }
        let next = VisibilityPolicy.moving(app, to: rule, before: target, apps: apps, host: Self.host)
        guard next != apps else { return }
        previousLayout = apps
        apps = next
        layoutChanged()
    }

    func undoLayoutChange() {
        guard let previousLayout else { return }
        apps = previousLayout
        self.previousLayout = nil
        layoutChanged()
    }

    @discardableResult
    func move(id: String, to rule: IconVisibility, before target: String? = nil) -> Bool {
        guard let app = layoutApps.first(where: { $0.id == id }) else { return false }
        move(app, to: rule, before: target)
        return true
    }

    func remove(id: String) {
        previousLayout = apps
        apps.removeAll { $0.id == id }
        layoutChanged()
    }

    private func layoutChanged() {
        cancelGlyphCapture()
        cancelNativeMenu()
        if hiddenCount == 0 { isRevealed = false }
        persist()
        applyNativeVisibility()
        scheduleAutoHide()
        if hasScreenRecording { refreshMenuGlyphs() }
    }

    func add(url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              VisibilityPolicy.canHide(id, host: Self.host) else {
            actionError = "Choose an app. Tuck and system icons stay visible."
            return
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        previousLayout = apps
        apps.removeAll { $0.id == id }
        apps.append(TuckedApp(id: id, name: name, path: url.path, visibility: .show))
        layoutChanged()
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.add(url: url)
        }
    }

    var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier, $0.bundleURL != nil else { return false }
            return VisibilityPolicy.canHide(id, host: Self.host) &&
                !apps.contains(where: { $0.id == id }) && $0.activationPolicy != .prohibited &&
                !($0.bundleURL?.path.contains("/Contents/") ?? false)
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    func requestAccessibility() {
        _ = TKRequestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestMenuImages() {
        hasScreenRecording = CGRequestScreenCaptureAccess()
        if hasScreenRecording { refreshMenuGlyphs(force: true) }
        else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installGlyphs(_ values: [MenuGlyphData]) {
        let owners = Set(values.map { $0.record.owner })
        for obsolete in glyphRecords where owners.contains(obsolete.owner) { glyphImages.removeValue(forKey: obsolete.key) }
        glyphRecords.removeAll { owners.contains($0.owner) }
        for value in values {
            guard let image = NSImage(data: value.png) else { continue }
            image.size = NSSize(width: value.record.width, height: value.record.height)
            image.isTemplate = value.record.isTemplate
            glyphImages[value.record.key] = image
            glyphRecords.append(value.record)
        }
    }

    private func cancelGlyphCapture() {
        glyphGeneration += 1
        glyphTask?.cancel(); glyphTask = nil
        if isCapturingIcons { temporaryApp = nil }
        isCapturingIcons = false
    }

    func refreshMenuGlyphs(force: Bool = false) {
        guard hasAccessibility, hasScreenRecording, !isCapturingIcons, temporaryApp == nil else { return }
        let visibleItems = layoutApps.filter { $0.visibility == .show && !entries(for: $0).isEmpty }
        let candidates = VisibilityPolicy.normalized(pocketApps + visibleItems, host: Self.host)
        let pending = candidates.filter { app in
            force || !glyphRecords.contains { $0.owner == app.id && glyphImages[$0.key] != nil }
        }
        guard !pending.isEmpty, let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let screenRect = CGRect(x: screen.frame.minX, y: NSScreen.screens.first.map { $0.frame.maxY - screen.frame.maxY } ?? 0,
                                width: screen.frame.width, height: screen.frame.height)
        let barHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        glyphGeneration += 1
        let revision = glyphGeneration
        isCapturingIcons = true
        iconCaptureError = nil
        onChange?()
        glyphTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.glyphGeneration == revision {
                    self.temporaryApp = nil
                    self.isCapturingIcons = false
                    self.applyNativeVisibility()
                }
            }
            for app in pending {
                guard !Task.isCancelled, self.glyphGeneration == revision,
                      let current = self.layoutApps.first(where: { $0.id == app.id }),
                      current.visibility != .neverShow,
                      self.owner(for: app) != nil else { continue }
                let reveal = current.visibility == .hide ? current.id : nil
                if reveal != self.temporaryApp {
                    self.temporaryApp = reveal
                    self.applyNativeVisibility()
                }
                do {
                    for _ in 0..<100 where self.isApplying { try await Task.sleep(for: .milliseconds(50)) }
                    try Task.checkCancellation()
                    guard self.glyphGeneration == revision, self.visibilityError == nil, !self.isApplying else { return }
                    try await Task.sleep(for: .milliseconds(300))
                    let icons = await self.readMenuIcons(for: app)
                    try Task.checkCancellation()
                    guard self.glyphGeneration == revision else { return }
                    let owned = icons.filter { self.matches($0, app: app) }
                    let images = try await self.glyphStore.capture(owner: app.id, items: owned,
                        screen: screenRect, barHeight: barHeight, scale: scale)
                    try Task.checkCancellation()
                    guard self.glyphGeneration == revision else { return }
                    self.menuIcons.removeAll { self.matches($0, app: app) }
                    self.menuIcons.append(contentsOf: owned)
                    self.installGlyphs(images)
                    self.onChange?()
                } catch is CancellationError { return }
                catch { self.iconCaptureError = "\(app.name): \(error.localizedDescription)" }
            }
        }
    }

    func refreshMenuApps() {
        refreshGeneration += 1
        let revision = refreshGeneration
        refreshTask?.cancel()
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        if isCapturingIcons && (!hasAccessibility || !hasScreenRecording) {
            cancelGlyphCapture()
            applyNativeVisibility()
        }
        guard hasAccessibility else {
            if temporaryApp != nil { finishNativeMenu() }
            isReadingMenu = false
            menuReadFailed = false
            menuIcons = []
            if isRevealed { hide() }
            onChange?()
            return
        }
        isReadingMenu = true
        menuReadFailed = false
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let icons = await self.readMenuIcons()
            guard !Task.isCancelled, self.refreshGeneration == revision else { return }
            let freshIDs = Set(icons.map(\.id))
            let livePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            let savedHidden = self.apps.filter { $0.visibility != .show }
            self.menuIcons = icons + self.menuIcons.filter { icon in
                livePIDs.contains(icon.pid) && !freshIDs.contains(icon.id) && savedHidden.contains { self.matches(icon, app: $0) }
            }
            let owners = Set(icons.map(\.pid))
            let systemEntries = icons.compactMap { icon -> TuckedApp? in
                guard let system = icon.systemItem else { return nil }
                return TuckedApp(id: system.id, name: system.title, path: "", visibility: .show, ownerBundleID: icon.ownerBundleID)
            }
            let appEntries = NSWorkspace.shared.runningApplications.compactMap { app -> TuckedApp? in
                guard owners.contains(app.processIdentifier), let id = app.bundleIdentifier,
                      let url = app.bundleURL, VisibilityPolicy.canHide(id, host: Self.host) else { return nil }
                return TuckedApp(id: id, name: app.localizedName ?? id, path: url.path, visibility: .show)
            }
            self.detectedApps = VisibilityPolicy.normalized(systemEntries + appEntries, host: Self.host)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var updated = self.apps
            for index in updated.indices where updated[index].systemItem != nil {
                if let fresh = systemEntries.first(where: { $0.id == updated[index].id }) {
                    updated[index].ownerBundleID = fresh.ownerBundleID
                }
            }
            if updated != self.apps { self.apps = updated; self.persist(); self.applyNativeVisibility() }
            self.isReadingMenu = false
            self.menuReadFailed = self.detectedApps.isEmpty
            self.onChange?()
            if self.hasScreenRecording { self.refreshMenuGlyphs() }
        }
        onChange?()
    }

    func setPocketStyle(_ value: PocketStyle) {
        pocketStyle = value
        defaults.set(value.rawValue, forKey: "pocketStyle")
        onChange?()
    }

    func setDelay(_ value: AutoHideDelay) {
        delay = value
        defaults.set(value.rawValue, forKey: "autoHideDelay")
        scheduleAutoHide()
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if value && !launchAtLogin { actionError = "Allow Tuck in System Settings → General → Login Items." }
        } catch { actionError = error.localizedDescription }
    }

    func scheduleAutoHide() {
        timer?.cancel(); timer = nil
        guard isRevealed, hiddenCount > 0, delay != .off else { return }
        timer = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.delay.rawValue)) } catch { return }
            guard !Task.isCancelled, self.isRevealed else { return }
            if self.settingsOpen || Self.pointerInMenuBar || self.isPointerInPocket?() == true {
                self.scheduleAutoHide()
            } else { self.hide() }
        }
    }

    private static var pointerInMenuBar: Bool {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                          width: screen.frame.width, height: height).contains(location)
        }
    }

    private func runningAppsChanged() {
        if let temporaryApp, let app = apps.first(where: { $0.id == temporaryApp }), !isRunning(app) { cancelNativeMenu() }
        if managedCount > 0 { applyNativeVisibility() }
        refreshMenuApps()
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(apps), forKey: "apps") }
        catch { actionError = "Could not save your app list. \(error.localizedDescription)" }
    }
}
