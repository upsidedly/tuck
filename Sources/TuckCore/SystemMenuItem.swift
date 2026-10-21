import Foundation

/// Individually managed system controls. Clock and Control Center are fixed.
public enum SystemMenuItem: String, CaseIterable, Sendable {
    case battery, bluetooth, displays, inputSource, sound, wifi, screenMirroring, siri, spotlight

    public var id: String { "tuck.system." + rawValue }
    public init?(id: String) {
        guard let item = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = item
    }
    public var title: String {
        switch self {
        case .battery: "Battery"
        case .bluetooth: "Bluetooth"
        case .displays: "Displays"
        case .inputSource: "Input Source"
        case .sound: "Sound"
        case .wifi: "Wi-Fi"
        case .screenMirroring: "Screen Mirroring"
        case .siri: "Siri"
        case .spotlight: "Spotlight"
        }
    }
    public var symbol: String {
        switch self {
        case .battery: "battery.100"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .displays: "display"
        case .inputSource: "keyboard"
        case .sound: "speaker.wave.2"
        case .wifi: "wifi"
        case .screenMirroring: "rectangle.on.rectangle"
        case .siri: "waveform.circle"
        case .spotlight: "magnifyingglass"
        }
    }
    /// Values verified from MenuBarClientCore on macOS 27.2.
    public var nativeIdentifier: Int? {
        switch self {
        case .battery: 0
        case .bluetooth: 1
        case .displays: 3
        case .inputSource: 4
        case .sound: 5
        case .wifi: 6
        case .screenMirroring: 7
        case .siri, .spotlight: nil
        }
    }
    public func canRestrictOwner(_ bundleID: String) -> Bool {
        switch self {
        case .inputSource: bundleID == "com.apple.TextInputMenuAgent"
        case .siri: ["com.apple.systemuiserver", "com.apple.Siri"].contains(bundleID)
        case .spotlight: ["com.apple.campo", "com.apple.Spotlight"].contains(bundleID)
        default: false
        }
    }

    public static func match(identifier: String, label: String, owner: String) -> Self? {
        guard owner.hasPrefix("com.apple.") else { return nil }
        switch identifier.lowercased() {
        case "com.apple.menuextra.battery": return .battery
        case "com.apple.menuextra.bluetooth": return .bluetooth
        case "com.apple.menuextra.display", "com.apple.menuextra.displays": return .displays
        case "com.apple.menuextra.keyboard", "com.apple.menuextra.textinput": return .inputSource
        case "com.apple.menuextra.volume", "com.apple.menuextra.sound": return .sound
        case "com.apple.menuextra.wifi": return .wifi
        case "com.apple.menuextra.mirroring", "com.apple.menuextra.screenmirroring": return .screenMirroring
        case "com.apple.menuextra.siri": return .siri
        case "com.apple.menuextra.spotlight": return .spotlight
        default: break
        }
        if owner == "com.apple.TextInputMenuAgent" { return .inputSource }
        if owner == "com.apple.campo" || owner == "com.apple.Spotlight" { return .spotlight }
        if ["com.apple.systemuiserver", "com.apple.Siri"].contains(owner), label.localizedCaseInsensitiveContains("siri") { return .siri }
        return nil
    }
}
