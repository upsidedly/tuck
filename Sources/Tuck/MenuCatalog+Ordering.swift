import ApplicationServices
import Foundation
import TuckCore

extension MenuCatalog {
    /// Moves visible owners around the fixed caret while the native visibility
    /// assertion continues to suppress every hidden and Never-Show owner.
    func arrange(order: [String], host: String, agentPID: pid_t?, clientPIDs: [pid_t],
                 owners: [pid_t: String], bar: CGRect, drag: MenuBarDragController) async throws -> [String] {
        guard AXIsProcessTrusted() else { throw MenuOrderError.accessibility }
        let wanted = Set(order)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        func snapshot() async throws -> [MenuIcon] {
            var missing = host
            for attempt in 0..<4 {
                try Task.checkCancellation()
                let items = read(agentPID: agentPID, clientPIDs: clientPIDs, owners: owners)
                    .filter { wanted.contains(Self.orderID($0, host: host)) }
                let invalid = items.first { item in
                    guard let frame = item.frame else { return true }
                    return frame.width <= 0 || frame.height <= 0 || !bar.contains(frame)
                }
                if invalid == nil, items.contains(where: { Self.orderID($0, host: host) == host }) {
                    return items.sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
                }
                missing = invalid.map { Self.orderID($0, host: host) } ?? host
                if attempt < 3 { try await Task.sleep(for: .milliseconds(150)) }
            }
            throw MenuOrderError.unavailable(missing)
        }
        func ownerID(_ icon: MenuIcon) -> String { Self.orderID(icon, host: host) }
        func match(_ reference: MenuIcon, in items: [MenuIcon]) -> Int? {
            items.firstIndex { $0.id == reference.id ||
                (ownerID($0) == ownerID(reference) && !reference.identifier.isEmpty && $0.identifier == reference.identifier) }
        }
        var current = try await snapshot()
        let available = Set(current.map(ownerID))
        let desired = order.filter { available.contains($0) }
        guard let caret = desired.firstIndex(of: host) else { throw MenuOrderError.unavailable(host) }
        var steps: [(owner: String, target: String, before: Bool)] = []
        var anchor = host
        for id in desired[..<caret].reversed() { steps.append((id, anchor, true)); anchor = id }
        anchor = host
        for id in desired.dropFirst(caret + 1) { steps.append((id, anchor, false)); anchor = id }
        for step in steps {
            guard step.owner != host, VisibilityPolicy.canHide(step.owner, host: host) else { continue }
            var target = step.before ? current.first(where: { ownerID($0) == step.target })
                : current.last(where: { ownerID($0) == step.target })
            let group = current.filter { ownerID($0) == step.owner }
            for original in (step.before ? Array(group.reversed()) : group) {
                guard let initialTarget = target else { throw MenuOrderError.unavailable(step.target) }
                var placed = false
                for attempt in 0..<2 {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw MenuOrderError.didNotMove }
                    guard let sourceIndex = match(original, in: current), let targetIndex = match(initialTarget, in: current),
                          let from = current[sourceIndex].frame, let to = current[targetIndex].frame else {
                        throw MenuOrderError.unavailable(step.owner)
                    }
                    if step.before ? sourceIndex < targetIndex : sourceIndex > targetIndex {
                        placed = true; break
                    }
                    // A wide item may need its entire footprint to cross the
                    // target. Use that margin only after a normal drop fails.
                    let margin = attempt == 0 ? -2 : from.width / 2 + 2
                    let proposed = step.before ? to.minX - margin : to.maxX + margin
                    let destination = CGPoint(x: min(bar.maxX - from.width / 2,
                        max(bar.minX + from.width / 2, proposed)), y: to.midY)
                    try await drag.move(from: CGPoint(x: from.midX, y: from.midY), to: destination)
                    try await Task.sleep(for: .milliseconds(250))
                    current = try await snapshot()
                }
                if !placed, let sourceIndex = match(original, in: current), let targetIndex = match(initialTarget, in: current) {
                    placed = step.before ? sourceIndex < targetIndex : sourceIndex > targetIndex
                }
                guard placed else { throw MenuOrderError.didNotMove }
                target = match(original, in: current).map { current[$0] }
            }
        }
        let confirmed = current.map(ownerID).reduce(into: [String]()) { result, id in
            if result.last != id { result.append(id) }
        }
        guard confirmed == desired else { throw MenuOrderError.didNotMove }
        return confirmed
    }

    private static func orderID(_ icon: MenuIcon, host: String) -> String {
        icon.identifier == "tuck-menu-bar" ? host : icon.systemItem?.id ?? icon.ownerBundleID
    }
}
