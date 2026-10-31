import AppKit
import ApplicationServices
import OSLog
import TuckCore

/// Owns the short handoff from a blocked Clock gesture to the native system
/// shortcut. The saved restriction is restored as soon as the panel appears.
@MainActor
final class ClockActivationBridge {
    var shouldBridge: () -> Bool = { false }
    var clockFrame: () -> CGRect? = { nil }
    var prepareHandoff: () -> Void = {}
    var releaseRestriction: () -> Void = {}
    var restoreRestriction: () -> Void = {}
    var pressClock: () async -> Bool = { false }
    var waitForRestoration: () async -> Bool = { true }
    var reportError: (String) -> Void = { _ in }

    private(set) var isActive = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var task: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let cover = MenuBarVisibilityCover()
    private let panelReader = NotificationCenterPanelReader()
    private var generation = 0
    private var mouseDown: CGPoint?
    private var cancelledDrag = false
    private var pendingKeyUp: Int64?
    private var shortcut = NotificationCenterShortcut(hotKeys: [:])
    private static let replayMarker: Int64 = 0x5455434B434C4F43
    private let logger = Logger(subsystem: "dev.matthew.tuck", category: "ClockActivation")
    private static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    private(set) var panelVisible = false

    func synchronize(hasAccessibility: Bool) {
        shortcut = NotificationCenterShortcut(hotKeys: UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:])
        guard hasAccessibility else { stop(restoring: true); return }
        if stateTask == nil, !isActive {
            let revision = generation
            stateTask = Task { [weak self] in
                guard let self else { return }
                let visible = await self.readPanelState()
                guard !Task.isCancelled, self.generation == revision else { return }
                self.panelVisible = visible
                self.stateTask = nil
            }
        }
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ClockActivationBridge>.fromOpaque(context).takeUnretainedValue()
                let suppress = MainActor.assumeIsolated { owner.handle(type, event: event) == nil }
                return suppress ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop(restoring: Bool = false) {
        generation += 1
        task?.cancel(); task = nil
        stateTask?.cancel(); stateTask = nil
        deadline?.cancel(); deadline = nil
        if restoring, isActive { restoreRestriction() }
        cover.hide()
        isActive = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; mouseDown = nil; pendingKeyUp = nil
    }

    func activate() {
        guard task == nil else { return }
        guard shouldBridge() else {
            if let shortcut { post(shortcut) }
            return
        }
        generation += 1
        let revision = generation
        isActive = true
        stateTask?.cancel(); stateTask = nil
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.generation == revision else { return }
            self.stop(restoring: true)
            self.reportError("Notification Centre took too long to respond. Try again.")
        }
        task = Task { [weak self] in
            guard let self else { return }
            var needsRestoration = false
            defer {
                if self.generation == revision {
                    if needsRestoration { self.restoreRestriction() }
                    self.cover.hide()
                    self.deadline?.cancel(); self.deadline = nil
                    self.isActive = false; self.task = nil
                }
            }
            do {
                let initialState = await self.readPanelState()
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                self.panelVisible = initialState
                let opening = !self.panelVisible
                self.logger.debug("Starting Clock handoff; opening: \(opening)")
                self.prepareHandoff()
                guard await self.waitForRestoration(), self.generation == revision, !Task.isCancelled else { return }
                let covered = try await self.cover.show()
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                if !covered {
                    self.reportError("Allow Screen Recording to keep icons hidden when opening Notification Centre.")
                }
                self.releaseRestriction()
                needsRestoration = true
                // Invalidation is delivered asynchronously by MenuBarAgent.
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                var observed = false
                if let shortcut = self.shortcut, self.post(shortcut) {
                    for _ in 0..<12 {
                        try await Task.sleep(for: .milliseconds(50))
                        guard self.generation == revision else { return }
                        let visible = await self.readPanelState()
                        try Task.checkCancellation()
                        guard self.generation == revision else { return }
                        self.panelVisible = visible
                        if self.panelVisible == opening { observed = true; break }
                    }
                }
                if !observed {
                    // macOS can ignore a synthetic Fn shortcut. Press the real
                    // Clock once, only after confirming the panel did not move.
                    let pressed = await self.pressClock()
                    try Task.checkCancellation()
                    guard self.generation == revision else { return }
                    self.logger.debug("Clock fallback accepted: \(pressed)")
                    for _ in 0..<40 {
                        try await Task.sleep(for: .milliseconds(50))
                        guard self.generation == revision else { return }
                        let visible = await self.readPanelState()
                        try Task.checkCancellation()
                        guard self.generation == revision else { return }
                        self.panelVisible = visible
                        if self.panelVisible == opening { observed = true; break }
                    }
                }
                self.restoreRestriction()
                self.logger.debug("Restoring hidden layout; panel transition observed: \(observed)")
                needsRestoration = false
                guard await self.waitForRestoration(), self.generation == revision, !Task.isCancelled else { return }
                guard observed else {
                    self.reportError("Notification Centre did not respond. Try again.")
                    return
                }
                try await Task.sleep(for: .milliseconds(150))
                let finalState = await self.readPanelState()
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                self.panelVisible = finalState
                if opening, !self.panelVisible {
                    self.reportError("macOS closed Notification Centre while restoring the menu bar.")
                }
            } catch is CancellationError { return }
            catch { self.reportError(error.localizedDescription) }
        }
    }

    private var notificationCenterPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
    }

    private func readPanelState() async -> Bool {
        guard let pid = notificationCenterPID else { return false }
        let screens = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        return await panelReader.isVisible(pid: pid, screens: screens)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown, shouldBridge(),
           event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
           let frame = clockFrame(), frame.width > 0, frame.height > 0, frame.contains(event.location) {
            mouseDown = event.location; cancelledDrag = isActive
            return nil
        }
        if type == .leftMouseDragged, let down = mouseDown {
            if hypot(down.x - event.location.x, down.y - event.location.y) > 5 { cancelledDrag = true }
            return nil
        }
        if type == .leftMouseUp, mouseDown != nil {
            mouseDown = nil
            if !cancelledDrag { activate() }
            return nil
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, pendingKeyUp == code { pendingKeyUp = nil; return nil }
        if type == .keyDown, shouldBridge(), !isActive, let shortcut,
           code == Int64(shortcut.keyCode),
           event.flags.intersection(Self.modifierMask).rawValue == shortcut.flags & Self.modifierMask.rawValue {
            pendingKeyUp = code
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { activate() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func post(_ shortcut: NotificationCenterShortcut) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = CGEventFlags(rawValue: shortcut.flags)
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            // System symbolic shortcuts are handled before the session tap.
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Reads only panel identifiers and geometry, never notification text. Banner
/// windows and desktop widgets exist independently of the open centre.
private actor NotificationCenterPanelReader {
    func isVisible(pid: pid_t, screens: [CGRect]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        var remaining = 64
        func visit(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth < 7, remaining > 0, !Task.isCancelled else { return false }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.03)
            let identifier = value(element, kAXIdentifierAttribute) as? String ?? ""
            if identifier == "AXNotificationListItems" || identifier == "widgets-overlay-view" {
                guard value(element, "AXHidden") as? Bool != true,
                      let rect = frame(element), rect.width > 1, rect.height > 1 else { return false }
                return screens.contains { $0.intersects(rect) }
            }
            return (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains { visit($0, depth: depth + 1) }
        }
        return windows.prefix(8).contains { visit($0, depth: 0) }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
