import Foundation

/// Visibility rules and the visible row's order share one saved snapshot.
/// The host ID is an immovable marker, never a rule that can be hidden.
public struct MenuLayout: Codable, Equatable, Sendable {
    public var apps: [TuckedApp]
    public var alwaysShowOrder: [String]

    public init(apps: [TuckedApp], alwaysShowOrder: [String] = [], host: String) {
        self.apps = VisibilityPolicy.normalized(apps, host: host)
        self.alwaysShowOrder = alwaysShowOrder.isEmpty ? []
            : Self.visibleOrder(apps: self.apps, preferred: alwaysShowOrder, host: host)
    }

    public func row(_ rule: IconVisibility, host: String) -> [String] {
        if rule == .show { return Self.visibleOrder(apps: apps, preferred: alwaysShowOrder, host: host) }
        return VisibilityPolicy.normalized(apps, host: host).filter { $0.visibility == rule }.map(\.id)
    }

    /// Persist newly discovered owners in Pocket, keeping explicit rules and
    /// ordering intact even when an owner temporarily removes its status item.
    public func discovering(_ discovered: [TuckedApp], host: String) -> MenuLayout {
        var merged = apps
        for item in VisibilityPolicy.normalized(discovered, host: host) {
            if let index = merged.firstIndex(where: { $0.id == item.id }) {
                merged[index].name = item.name
                merged[index].path = item.path
                merged[index].ownerBundleID = item.ownerBundleID
            } else {
                var added = item
                added.visibility = .hide
                merged.append(added)
            }
        }
        return MenuLayout(apps: merged, alwaysShowOrder: alwaysShowOrder, host: host)
    }

    public func moving(id: String, to rule: IconVisibility, before target: String? = nil, host: String) -> MenuLayout {
        guard id != target, VisibilityPolicy.canHide(id, host: host),
              let app = apps.first(where: { $0.id == id }) else { return self }
        let nextApps = VisibilityPolicy.moving(app, to: rule, before: target, apps: apps, host: host)
        var visible = row(.show, host: host).filter { $0 != id }
        if rule == .show {
            let index = target.flatMap { visible.firstIndex(of: $0) } ?? visible.endIndex
            visible.insert(id, at: index)
        }
        return MenuLayout(apps: nextApps, alwaysShowOrder: visible, host: host)
    }

    /// Move an app by one visible slot, including across the fixed caret.
    public func shifting(id: String, by offset: Int, host: String) -> MenuLayout {
        guard offset == -1 || offset == 1, let app = apps.first(where: { $0.id == id }) else { return self }
        let items = row(app.visibility, host: host)
        guard let index = items.firstIndex(of: id), items.indices.contains(index + offset) else { return self }
        let destination = offset < 0 ? index - 1 : index + 2
        let target = items.indices.contains(destination) ? items[destination] : nil
        return moving(id: id, to: app.visibility, before: target, host: host)
    }

    public func removing(id: String, host: String) -> MenuLayout {
        guard VisibilityPolicy.canHide(id, host: host) else { return self }
        return MenuLayout(apps: apps.filter { $0.id != id },
            alwaysShowOrder: alwaysShowOrder.filter { $0 != id }, host: host)
    }

    private static func visibleOrder(apps: [TuckedApp], preferred: [String], host: String) -> [String] {
        let visible = VisibilityPolicy.normalized(apps, host: host).filter { $0.visibility == .show }.map(\.id)
        let allowed = Set(visible).union([host])
        var seen = Set<String>()
        var result = preferred.filter { allowed.contains($0) && seen.insert($0).inserted }
        if !seen.contains(host) { result.append(host); seen.insert(host) }
        // Newly discovered icons join the left of the caret until explicitly placed.
        let newItems = visible.filter { !seen.contains($0) }
        let anchor = result.firstIndex(of: host) ?? result.endIndex
        result.insert(contentsOf: newItems, at: anchor)
        return result
    }
}
