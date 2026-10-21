import AppKit

/// Keeps the native item available for the lifetime of its real menu/popover.
/// Window metadata is sufficient; no screen pixels are read.
@MainActor
final class NativeMenuTracker {
    struct WindowStamp: Hashable {
        let id: UInt32
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private var task: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onClosed: (() -> Void)?
    private var pid: pid_t = 0
    private var agentPID: pid_t?
    private var relatedPIDs: Set<pid_t> = []
    private var baseline: Set<WindowStamp> = []
    private var sawWindow = false

    static func windows(pid: pid_t, agentPID: pid_t?, relatedPIDs: Set<pid_t> = []) -> Set<WindowStamp> {
        let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(metadata.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  owner == pid || owner == agentPID || relatedPIDs.contains(owner),
                  let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"], height > 32, width > 16 else { return nil }
            return WindowStamp(id: id, x: Int(x), y: Int(y), width: Int(width), height: Int(height))
        })
    }

    func start(pid: pid_t, agentPID: pid_t?, relatedPIDs: Set<pid_t> = [], baseline: Set<WindowStamp>, onClosed: @escaping () -> Void) {
        stop()
        self.pid = pid
        self.agentPID = agentPID
        self.relatedPIDs = relatedPIDs
        self.baseline = baseline
        self.onClosed = onClosed
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterEvent() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.checkAfterEvent() }
            return event
        }
        task = Task { [weak self] in
            // Poll briefly for an opening menu, then for closure. If a menu is
            // held open for two minutes, input events take over closure checks.
            for tick in 0..<480 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.hasWindow { self.sawWindow = true }
                else if self.sawWindow || tick >= 7 { self.finish(); return }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        eventTask?.cancel(); eventTask = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        onClosed = nil
        sawWindow = false
        relatedPIDs = []
    }

    private var hasWindow: Bool { !Self.windows(pid: pid, agentPID: agentPID, relatedPIDs: relatedPIDs).subtracting(baseline).isEmpty }

    private func checkAfterEvent() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.hasWindow { self.sawWindow = true }
            else if self.sawWindow { self.finish() }
        }
    }

    private func finish() {
        let completion = onClosed
        stop()
        completion?()
    }
}
