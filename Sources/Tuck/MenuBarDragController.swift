import ApplicationServices

enum MenuOrderError: Error {
    case unavailable(String)
    case didNotMove
    case inputBusy
    case accessibility
}

/// Owns one short native Command-drag, including release and cursor cleanup.
/// Uses the existing Accessibility grant; no menu-bar file is accessed.
@MainActor
final class MenuBarDragController {
    private var source: CGEventSource?
    private var original: CGPoint?
    private var last = CGPoint.zero
    private var mouseDown = false
    private var cursorHidden = false
    private var generation = 0

    func move(from: CGPoint, to: CGPoint) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw MenuOrderError.accessibility }
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right) else { throw MenuOrderError.inputBusy }
        cancel()
        guard let source = CGEventSource(stateID: .hidSystemState), let original = CGEvent(source: nil)?.location else {
            throw MenuOrderError.inputBusy
        }
        let permitted: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
        self.source = source; self.original = original; last = from
        cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        let revision = generation
        defer { if generation == revision { finish() } }

        try post(.leftMouseDown, at: from, command: true); mouseDown = true
        try await pause(.milliseconds(30), revision: revision)
        try post(.leftMouseDragged, at: to, command: true)
        try await pause(.milliseconds(20), revision: revision)
        try post(.leftMouseUp, at: to, command: false); mouseDown = false
        // Let the queued drop reach the session before restoring the pointer.
        try await pause(.milliseconds(40), revision: revision)
    }

    func cancel() { generation += 1; finish() }

    private func pause(_ duration: Duration, revision: Int) async throws {
        try await Task.sleep(for: duration)
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
    }

    private func finish() {
        if mouseDown, let source {
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: last, mouseButton: .left)
            up?.flags = []; up?.post(tap: .cgSessionEventTap)
        }
        mouseDown = false
        if let original { CGWarpMouseCursorPosition(original) }
        if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        source = nil; original = nil; cursorHidden = false
    }

    private func post(_ type: CGEventType, at point: CGPoint, command: Bool) throws {
        guard let source, let event = CGEvent(mouseEventSource: source, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left) else { throw MenuOrderError.inputBusy }
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 0x5455434b) // TUCK
        event.post(tap: .cgSessionEventTap)
        last = point
    }
}
