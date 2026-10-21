import Carbon

@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static weak var active: HotKey?
    var onPress: (() -> Void)?

    func register() -> Bool {
        Self.active = self
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.active?.onPress?() }
            return noErr
        }, 1, &event, nil, &handler)
        guard installed == noErr else { return false }
        let identifier = EventHotKeyID(signature: 0x5455434B, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), identifier,
                                        GetApplicationEventTarget(), 0, &reference)
        return result == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
