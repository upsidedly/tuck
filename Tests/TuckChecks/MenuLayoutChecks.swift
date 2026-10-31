import Foundation
import TuckCore

func menuLayoutsKeepAnImmovableCaret() throws {
    let host = "dev.tuck"
    func app(_ id: String, _ rule: IconVisibility = .show) -> TuckedApp {
        TuckedApp(id: id, name: id, path: "", visibility: rule)
    }
    let a = app("dev.a"), b = app("dev.b"), c = app("dev.c", .hide), d = app("dev.d", .neverShow)
    let initial = MenuLayout(apps: [a, b, c, d], alwaysShowOrder: [a.id, host, b.id], host: host)

    let clean = MenuLayout(apps: [a, b, c, app(host, .neverShow)],
        alwaysShowOrder: [host, host, "unknown", c.id, b.id], host: host)
    precondition(clean.row(.show, host: host) == [a.id, host, b.id])
    precondition(!clean.row(.hide, host: host).contains(host))
    precondition(!clean.row(.neverShow, host: host).contains(host))
    for rule in IconVisibility.allCases {
        precondition(initial.moving(id: host, to: rule, before: a.id, host: host) == initial)
    }
    precondition(initial.removing(id: host, host: host) == initial)
    precondition(initial.shifting(id: host, by: 1, host: host) == initial)

    let right = initial.moving(id: a.id, to: .show, host: host)
    precondition(right.row(.show, host: host) == [host, b.id, a.id])
    let left = right.moving(id: b.id, to: .show, before: host, host: host)
    precondition(left.row(.show, host: host) == [b.id, host, a.id])
    let crossedLeft = left.shifting(id: a.id, by: -1, host: host)
    precondition(crossedLeft.row(.show, host: host) == [b.id, a.id, host])
    precondition(crossedLeft.shifting(id: a.id, by: 1, host: host).row(.show, host: host) == [b.id, host, a.id])
    precondition(initial.moving(id: a.id, to: .show, before: a.id, host: host) == initial)
    precondition(initial.shifting(id: a.id, by: -1, host: host) == initial)
    precondition(initial.shifting(id: b.id, by: 1, host: host) == initial)
    precondition(initial.shifting(id: a.id, by: Int.min, host: host) == initial)

    let revealed = initial.moving(id: c.id, to: .show, before: host, host: host)
    precondition(revealed.row(.show, host: host) == [a.id, c.id, host, b.id])
    let hiddenAgain = revealed.moving(id: c.id, to: .hide, host: host)
    precondition(hiddenAgain.row(.show, host: host) == initial.row(.show, host: host))
    precondition(VisibilityPolicy.suppressedItems(apps: hiddenAgain.apps, host: host) == [c.id, d.id])
    precondition(!VisibilityPolicy.allowedBundles(running: [d.id], apps: revealed.apps, host: host).contains(d.id))

    let saved = try JSONEncoder().encode(left)
    let restored = try JSONDecoder().decode(MenuLayout.self, from: saved)
    precondition(restored == left)
    precondition(restored.row(.show, host: host) == [b.id, host, a.id])
    let migrated = MenuLayout(apps: initial.apps, host: host)
    precondition(migrated.row(.show, host: host) == [a.id, b.id, host])
    precondition(migrated.apps == initial.apps)

    for rule in IconVisibility.allCases {
        let owners = (1...3).map { app("dev.\($0)", rule) }
        let layout = MenuLayout(apps: owners, host: host)
        let moved = layout.moving(id: owners[2].id, to: rule, before: owners[0].id, host: host)
        precondition(moved.row(rule, host: host).filter { $0 != host } == [owners[2].id, owners[0].id, owners[1].id])
        precondition(moved.apps.allSatisfy { $0.visibility == rule })
        precondition(moved.apps.count == owners.count)
    }

    // The model materializes detected, unsaved apps before a drop, so targets
    // absent from the old preference list still participate in ordering.
    let discovered = MenuLayout(apps: VisibilityPolicy.normalized([c, a, b], host: host), host: host)
    let beforeDetected = discovered.moving(id: b.id, to: .show, before: a.id, host: host)
    precondition(beforeDetected.row(.show, host: host) == [b.id, a.id, host])
}

func discoveryTucksNewIconsAndPreservesSavedChoices() throws {
    let host = "dev.tuck"
    let visible = TuckedApp(id: "dev.visible", name: "Visible", path: "old", visibility: .show)
    let hidden = TuckedApp(id: "dev.hidden", name: "Hidden", path: "", visibility: .neverShow)
    let initial = MenuLayout(apps: [visible, hidden], alwaysShowOrder: [host, visible.id], host: host)
    let renamed = TuckedApp(id: visible.id, name: "Renamed", path: "new", visibility: .hide)
    let fresh = TuckedApp(id: "dev.new", name: "New icon", path: "", visibility: .show)
    let protected = TuckedApp(id: host, name: "Tuck", path: "")
    let discovered = initial.discovering([renamed, fresh, fresh, protected], host: host)
    precondition(discovered.row(.show, host: host) == [host, visible.id])
    precondition(discovered.row(.hide, host: host) == [fresh.id])
    precondition(discovered.row(.neverShow, host: host) == [hidden.id])
    precondition(discovered.apps.first?.name == "Renamed" && discovered.apps.first?.path == "new")
    precondition(discovered.apps.count == 3)
    precondition(discovered.discovering([], host: host) == discovered)
    precondition(discovered.discovering([renamed, fresh], host: host) == discovered)
    let restored = try JSONDecoder().decode(MenuLayout.self, from: JSONEncoder().encode(discovered))
    precondition(restored == discovered)
}
