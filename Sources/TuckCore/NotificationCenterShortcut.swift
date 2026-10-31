import Foundation

public struct NotificationCenterShortcut: Equatable, Sendable {
    public let keyCode: UInt16
    public let flags: UInt64

    public init?(hotKeys: [String: Any]) {
        // macOS symbolic hotkey 163 is Show Notification Centre. An absent
        // override uses the system's Fn+N default; explicit disabling is kept.
        guard let entry = hotKeys["163"] as? [String: Any] else {
            keyCode = 45; flags = 0x800000; return
        }
        guard entry["enabled"] as? Bool != false,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
              let code = UInt16(exactly: parameters[1].intValue),
              let modifiers = UInt64(exactly: parameters[2].int64Value) else { return nil }
        keyCode = code; flags = modifiers
    }
}
