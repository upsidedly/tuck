import Foundation

public enum IconVisibility: String, CaseIterable, Codable, Sendable {
    case show, hide, neverShow

    public var title: String {
        switch self {
        case .show: "Always Show"
        case .hide: "Show in Bar"
        case .neverShow: "Never Show"
        }
    }
}

public struct TuckedApp: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var path: String
    public var ownerBundleID: String?
    public var visibility: IconVisibility
    public var systemItem: SystemMenuItem? { SystemMenuItem(id: id) }

    public init(id: String, name: String, path: String, visibility: IconVisibility = .hide, ownerBundleID: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.ownerBundleID = ownerBundleID
        self.visibility = visibility
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, visibility, isHidden, ownerBundleID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        ownerBundleID = try values.decodeIfPresent(String.self, forKey: .ownerBundleID)
        visibility = try values.decodeIfPresent(IconVisibility.self, forKey: .visibility)
            ?? ((try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? true) ? .hide : .show)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(path, forKey: .path)
        try values.encodeIfPresent(ownerBundleID, forKey: .ownerBundleID)
        try values.encode(visibility, forKey: .visibility)
    }
}

public enum VisibilityPolicy {
    public static func canHide(_ bundleID: String, host: String) -> Bool {
        if bundleID.hasPrefix("tuck.system.") { return SystemMenuItem(id: bundleID) != nil }
        return !bundleID.isEmpty && bundleID != host && !bundleID.hasPrefix("com.apple.")
    }

    public static func suppressedItems(apps: [TuckedApp], host: String, temporarilyVisible: String? = nil) -> Set<String> {
        Set(apps.filter {
            canHide($0.id, host: host) && ($0.visibility == .neverShow || ($0.visibility == .hide && $0.id != temporarilyVisible))
        }.map(\.id))
    }

    public static func suppressedBundles(apps: [TuckedApp], host: String, temporarilyVisible: String? = nil) -> Set<String> {
        let hidden = suppressedItems(apps: apps, host: host, temporarilyVisible: temporarilyVisible)
        return Set(apps.compactMap { app in
            guard hidden.contains(app.id) else { return nil }
            guard let system = app.systemItem else { return app.id }
            guard let owner = app.ownerBundleID, owner != host, system.canRestrictOwner(owner) else { return nil }
            return owner
        })
    }

    public static func allowedSystemItems(apps: [TuckedApp], host: String, temporarilyVisible: String? = nil) -> [Int] {
        let hidden = suppressedItems(apps: apps, host: host, temporarilyVisible: temporarilyVisible)
        let excluded = Set(apps.filter { hidden.contains($0.id) }.compactMap { $0.systemItem?.nativeIdentifier })
        return Array(0...8).filter { !excluded.contains($0) }
    }

    public static func allowedBundles(running: Set<String>, apps: [TuckedApp], host: String, temporarilyVisible: String? = nil) -> [String] {
        let hidden = suppressedBundles(apps: apps, host: host, temporarilyVisible: temporarilyVisible)
        // Keep the control and Apple components reachable, even with a stale saved selection.
        return running.union([host, "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.MenuBarAgent"])
            .subtracting(hidden).sorted()
    }

    public static func normalized(_ apps: [TuckedApp], host: String) -> [TuckedApp] {
        var seen = Set<String>()
        return apps.filter { canHide($0.id, host: host) && seen.insert($0.id).inserted }
    }

    public static func pocketApps(_ apps: [TuckedApp], host: String) -> [TuckedApp] {
        normalized(apps, host: host).filter { $0.visibility == .hide }
    }

    /// Saved rules survive quitting an app; Pocket only shows live owners.
    public static func pocketApps(_ apps: [TuckedApp], host: String, running: Set<String>) -> [TuckedApp] {
        pocketApps(apps, host: host).filter { running.contains($0.ownerBundleID ?? $0.id) }
    }

    /// Move one app between groups, preserving the order chosen in the editor.
    public static func moving(_ app: TuckedApp, to rule: IconVisibility, before target: String? = nil,
                              apps: [TuckedApp], host: String) -> [TuckedApp] {
        guard canHide(app.id, host: host) else { return apps }
        var result = normalized(apps.filter { $0.id != app.id }, host: host)
        var moved = app
        moved.visibility = rule
        let targetIndex = target.flatMap { id in result.firstIndex { $0.id == id && $0.visibility == rule } }
        let index = targetIndex ?? result.lastIndex(where: { $0.visibility == rule }).map { $0 + 1 } ?? result.endIndex
        result.insert(moved, at: index)
        return result
    }
}

public enum PocketStyle: String, CaseIterable, Codable, Sendable {
    case black, liquidGlass

    public var title: String { self == .black ? "Black" : "Liquid Glass" }
}

public enum AutoHideDelay: Int, CaseIterable, Codable, Sendable {
    case off = 0, five = 5, ten = 10, thirty = 30, sixty = 60

    public var title: String {
        switch self {
        case .off: "Never"
        case .five: "5 seconds"
        case .ten: "10 seconds"
        case .thirty: "30 seconds"
        case .sixty: "1 minute"
        }
    }
}
