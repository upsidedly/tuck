import ApplicationServices
import Foundation
import TuckCore

struct MenuIcon: Identifiable, Sendable {
    let id: String
    let pid: pid_t
    let ownerBundleID: String
    let identifier: String
    let label: String
    let frame: CGRect?
    var systemItem: SystemMenuItem? { SystemMenuItem.match(identifier: identifier, label: label, owner: ownerBundleID) }
}

/// Reads only the menu-bar accessibility trees. AX objects stay on this actor;
/// the main actor receives immutable ownership and geometry values.
actor MenuCatalog {
    private var elements: [String: AXUIElement] = [:]

    func read(agentPID: pid_t?, clientPIDs: [pid_t], owners: [pid_t: String] = [:]) -> [MenuIcon] {
        guard AXIsProcessTrusted() else { elements.removeAll(); return [] }
        var found: [MenuIcon] = []
        var current: [String: AXUIElement] = [:]
        var visited: [AXUIElement] = []
        var remaining = 1_200

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 7, remaining > 0, !Task.isCancelled,
                  !visited.contains(where: { CFEqual($0, element) }) else { return }
            remaining -= 1
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = Self.string(element, kAXRoleAttribute)
            if role == kAXButtonRole || role == kAXMenuBarItemRole {
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }
                let identifier = Self.string(element, kAXIdentifierAttribute)
                let label = [Self.string(element, kAXDescriptionAttribute), Self.string(element, kAXTitleAttribute),
                             Self.string(element, kAXHelpAttribute), identifier].first { !$0.isEmpty } ?? "Menu icon"
                let id = "\(pid)|\(identifier)|\(label)"
                guard current[id] == nil else { return }
                current[id] = element
                found.append(MenuIcon(id: id, pid: pid, ownerBundleID: owners[pid] ?? "", identifier: identifier,
                                      label: label, frame: Self.frame(element)))
                return
            }
            // Portals lead to another application's whole UI. Each client's
            // extras menu bar is queried separately, without reading its content.
            guard role != kAXApplicationRole || depth == 0 else { return }
            for child in Self.children(element) { visit(child, depth: depth + 1) }
        }

        if let agentPID {
            let agent = AXUIElementCreateApplication(agentPID)
            AXUIElementSetMessagingTimeout(agent, 0.25)
            visit(agent, depth: 0)
        }
        for pid in clientPIDs where !Task.isCancelled && remaining > 0 {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            if let extras = Self.element(app, kAXExtrasMenuBarAttribute) { visit(extras, depth: 1) }
        }
        elements = current
        return found
    }

    func press(id: String) -> Int32 {
        guard let element = elements[id] else { return AXError.invalidUIElement.rawValue }
        return AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(source, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // The CF type check above is the documented bridge for AXUIElement.
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
