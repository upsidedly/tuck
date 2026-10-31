import Foundation
import CoreGraphics
import TuckCore

func selectedAppsAreHiddenWhileOtherAppsAndHostStayReachable() {
    let selected = [TuckedApp(id: "dev.snap", name: "Snap", path: "/Applications/Snap.app"),
                    TuckedApp(id: "dev.never", name: "Never", path: "", visibility: .neverShow)]
    let allowed = VisibilityPolicy.allowedBundles(running: ["dev.snap", "dev.never", "dev.other"], apps: selected, host: "dev.tuck")
    precondition(!allowed.contains("dev.snap"))
    precondition(!allowed.contains("dev.never"))
    precondition(allowed.contains("dev.other"))
    precondition(allowed.contains("dev.tuck"))
    precondition(allowed.contains("com.apple.controlcenter"))
}

func temporaryActivationOnlyRevealsTheSelectedPocketApp() {
    let apps = [TuckedApp(id: "dev.snap", name: "Snap", path: ""),
                TuckedApp(id: "dev.never", name: "Never", path: "", visibility: .neverShow)]
    let allowed = VisibilityPolicy.allowedBundles(running: ["dev.snap", "dev.never", "dev.other"], apps: apps, host: "dev.tuck", temporarilyVisible: "dev.snap")
    precondition(allowed.contains("dev.snap"))
    precondition(allowed.contains("dev.other"))
    precondition(!allowed.contains("dev.never"))
    precondition(VisibilityPolicy.suppressedBundles(apps: apps, host: "dev.tuck", temporarilyVisible: "dev.snap") == ["dev.never"])
    precondition(VisibilityPolicy.suppressedBundles(apps: apps, host: "dev.tuck", temporarilyVisible: "dev.never") == ["dev.snap", "dev.never"])
}

func stalePreferencesCannotHideTuckOrSystemApps() {
    let apps = ["dev.tuck", "com.apple.MenuBarAgent", "com.apple.controlcenter", ""].map {
        TuckedApp(id: $0, name: $0, path: "")
    }
    precondition(VisibilityPolicy.normalized(apps, host: "dev.tuck").isEmpty)
    let allowed = VisibilityPolicy.allowedBundles(running: ["dev.tuck", "com.apple.MenuBarAgent"], apps: apps, host: "dev.tuck")
    precondition(allowed.contains("dev.tuck"))
    precondition(allowed.contains("com.apple.MenuBarAgent"))
}

func disabledSelectionAndNewlyLaunchedAppsRemainVisible() {
    let apps = [TuckedApp(id: "dev.snap", name: "Snap", path: "", visibility: .show)]
    let allowed = VisibilityPolicy.allowedBundles(running: ["dev.snap", "dev.new"], apps: apps, host: "dev.tuck")
    precondition(allowed.contains("dev.snap"))
    precondition(allowed.contains("dev.new"))
}

func savedSelectionsRoundTripWithoutDuplicates() throws {
    let app = TuckedApp(id: "dev.snap", name: "Snap", path: "/Applications/Snap.app", visibility: .neverShow)
    let data = try JSONEncoder().encode([app, app])
    let decoded = try JSONDecoder().decode([TuckedApp].self, from: data)
    precondition(VisibilityPolicy.normalized(decoded, host: "dev.tuck") == [app])
}

func earlierHidePreferencesMigrate() throws {
    let data = Data("[{\"id\":\"dev.hide\",\"name\":\"Hide\",\"path\":\"\",\"isHidden\":true},{\"id\":\"dev.show\",\"name\":\"Show\",\"path\":\"\",\"isHidden\":false}]".utf8)
    let apps = try JSONDecoder().decode([TuckedApp].self, from: data)
    precondition(apps.map(\.visibility) == [.hide, .show])
}

func pocketTracksRunningOwnersWithoutDiscardingSavedRules() throws {
    let apps = [TuckedApp(id: "dev.closed", name: "Closed", path: ""),
                TuckedApp(id: "dev.live", name: "Live", path: ""),
                TuckedApp(id: SystemMenuItem.displays.id, name: "Displays", path: "", ownerBundleID: "com.apple.MenuBarAgent"),
                TuckedApp(id: "dev.never", name: "Never", path: "", visibility: .neverShow),
                TuckedApp(id: "dev.always", name: "Always", path: "", visibility: .show)]
    let saved = try JSONEncoder().encode(apps)
    let running: Set<String> = ["dev.live", "com.apple.MenuBarAgent", "dev.never", "dev.always"]
    precondition(VisibilityPolicy.pocketApps(apps, host: "dev.tuck", running: running).map(\.id)
        == ["dev.live", SystemMenuItem.displays.id])
    precondition(VisibilityPolicy.pocketApps(apps, host: "dev.tuck", running: []).isEmpty)
    precondition(VisibilityPolicy.pocketApps(apps, host: "dev.tuck", running: running.union(["dev.closed"])).map(\.id)
        == ["dev.closed", "dev.live", SystemMenuItem.displays.id])
    let restored = try JSONDecoder().decode([TuckedApp].self, from: saved)
    precondition(restored == apps)
}

func draggingChangesOnlyTheChosenAppsGroup() {
    let one = TuckedApp(id: "dev.one", name: "One", path: "one", visibility: .show)
    let two = TuckedApp(id: "dev.two", name: "Two", path: "two", visibility: .neverShow)
    let moved = VisibilityPolicy.moving(one, to: .hide, apps: [one, two], host: "dev.tuck")
    precondition(moved.first(where: { $0.id == one.id })?.visibility == .hide)
    precondition(moved.first(where: { $0.id == two.id }) == two)
    precondition(moved.count == 2)
    precondition(VisibilityPolicy.suppressedBundles(apps: moved, host: "dev.tuck") == [one.id, two.id])
}

func movingAnIconBeforeAnotherPreservesItsSavedOrder() throws {
    let apps = ["c", "b", "a"].map { TuckedApp(id: "dev.\($0)", name: $0, path: $0, visibility: .show) }
    let moved = VisibilityPolicy.moving(apps[0], to: .show, before: "dev.a", apps: apps, host: "dev.tuck")
    precondition(moved.map(\.id) == ["dev.b", "dev.c", "dev.a"])
    let saved = try JSONDecoder().decode([TuckedApp].self, from: JSONEncoder().encode(moved))
    precondition(VisibilityPolicy.normalized(saved, host: "dev.tuck").map(\.id) == moved.map(\.id))
}

func repeatedMovesNeverDuplicateAnIcon() {
    let app = TuckedApp(id: "dev.one", name: "One", path: "one", visibility: .show)
    var layout = [app]
    for rule in [IconVisibility.hide, .neverShow, .show, .hide] {
        layout = VisibilityPolicy.moving(app, to: rule, apps: layout, host: "dev.tuck")
        precondition(layout.count == 1 && layout[0].visibility == rule)
    }
}

func protectedIconsCannotBeDraggedIntoHiddenGroups() {
    let saved = [TuckedApp(id: "dev.one", name: "One", path: "one")]
    for id in ["dev.tuck", "com.apple.controlcenter", ""] {
        let protected = TuckedApp(id: id, name: "System", path: "")
        precondition(VisibilityPolicy.moving(protected, to: .neverShow, apps: saved, host: "dev.tuck") == saved)
    }
}

func rasterFixture(background: [UInt8], foreground: [UInt8]?, fragments: [CGRect] = []) -> CGImage {
    let size = 24
    var bytes = Array(repeating: background, count: size * size).flatMap { $0 }
    if let foreground {
        for y in 7..<17 { for x in 9..<15 {
            for channel in 0..<4 { bytes[(y * size + x) * 4 + channel] = foreground[channel] }
        } }
    }
    for rect in fragments {
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
            for channel in 0..<4 { bytes[(y * size + x) * 4 + channel] = 255 }
        } }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        fatalError("Could not create raster test fixture")
    }
    return image
}

func clippedNeighborsAreRemovedWithoutErasingGlyphParts() {
    let edge = CGRect(x: 22, y: 10, width: 2, height: 3)
    guard let cleaned = MenuIconRaster.normalize(rasterFixture(background: [0,0,0,0], foreground: [255,255,255,255], fragments: [edge])) else {
        fatalError("Missing cleaned glyph")
    }
    precondition(cleaned.image.width == 8)
    let interiorDot = CGRect(x: 19, y: 10, width: 2, height: 2)
    guard let dotted = MenuIconRaster.normalize(rasterFixture(background: [0,0,0,0], foreground: [255,255,255,255], fragments: [interiorDot])) else {
        fatalError("Missing dotted glyph")
    }
    precondition(dotted.image.width >= 14)
    let pairedParts = [CGRect(x: 0, y: 8, width: 2, height: 4), CGRect(x: 22, y: 8, width: 2, height: 4)]
    guard let paired = MenuIconRaster.normalize(rasterFixture(background: [0,0,0,0], foreground: nil, fragments: pairedParts)) else {
        fatalError("Missing multipart glyph")
    }
    precondition(paired.image.width == 24)
}

func systemIconsHaveIndependentRulesAndProtectedControls() throws {
    let battery = TuckedApp(id: SystemMenuItem.battery.id, name: "Battery", path: "", visibility: .hide, ownerBundleID: "com.apple.MenuBarAgent")
    let wifi = TuckedApp(id: SystemMenuItem.wifi.id, name: "Wi-Fi", path: "", visibility: .neverShow, ownerBundleID: "com.apple.MenuBarAgent")
    let allowed = VisibilityPolicy.allowedSystemItems(apps: [battery, wifi], host: "dev.tuck")
    precondition(!allowed.contains(0) && !allowed.contains(6) && allowed.contains(3))
    precondition(allowed.contains(2) && allowed.contains(8))
    let temporary = VisibilityPolicy.allowedSystemItems(apps: [battery, wifi], host: "dev.tuck", temporarilyVisible: battery.id)
    precondition(temporary.contains(0) && !temporary.contains(6))
    precondition(!VisibilityPolicy.allowedSystemItems(apps: [battery, wifi], host: "dev.tuck", temporarilyVisible: wifi.id).contains(6))
    precondition(VisibilityPolicy.suppressedBundles(apps: [battery, wifi], host: "dev.tuck").isEmpty)
    precondition(!VisibilityPolicy.canHide("tuck.system.clock", host: "dev.tuck") && !VisibilityPolicy.canHide("tuck.system.controlCenter", host: "dev.tuck"))
    let moved = VisibilityPolicy.moving(battery, to: .show, apps: [battery, wifi], host: "dev.tuck")
    precondition(moved.first(where: { $0.id == wifi.id }) == wifi && VisibilityPolicy.allowedSystemItems(apps: moved, host: "dev.tuck").contains(0))
    let saved = try JSONDecoder().decode([TuckedApp].self, from: JSONEncoder().encode([battery, wifi]))
    precondition(saved == [battery, wifi] && saved[0].ownerBundleID == "com.apple.MenuBarAgent")
}

func systemHelperRulesDoNotHideOtherAppleControls() {
    let siri = TuckedApp(id: SystemMenuItem.siri.id, name: "Siri", path: "", ownerBundleID: "com.apple.systemuiserver")
    let spotlight = TuckedApp(id: SystemMenuItem.spotlight.id, name: "Spotlight", path: "", visibility: .show, ownerBundleID: "com.apple.campo")
    let running: Set<String> = ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.campo", "com.apple.controlcenter"]
    let allowed = VisibilityPolicy.allowedBundles(running: running, apps: [siri, spotlight], host: "dev.tuck")
    precondition(!allowed.contains("com.apple.systemuiserver") && allowed.contains("com.apple.campo"))
    precondition(allowed.contains("com.apple.MenuBarAgent") && allowed.contains("com.apple.controlcenter") && allowed.contains("dev.tuck"))
    let forged = TuckedApp(id: siri.id, name: siri.name, path: "", ownerBundleID: "com.apple.controlcenter")
    precondition(VisibilityPolicy.suppressedBundles(apps: [forged], host: "dev.tuck").isEmpty)
}

func systemDiscoveryUsesNativeIdentifiersAndKnownHelpers() {
    precondition(SystemMenuItem.match(identifier: "com.apple.menuextra.wifi", label: "Wi-Fi, connected", owner: "com.apple.MenuBarAgent") == .wifi)
    precondition(SystemMenuItem.match(identifier: "", label: "Menu icon", owner: "com.apple.TextInputMenuAgent") == .inputSource)
    precondition(SystemMenuItem.match(identifier: "", label: "Search", owner: "com.apple.campo") == .spotlight)
    precondition(SystemMenuItem.match(identifier: "", label: "Siri", owner: "com.apple.systemuiserver") == .siri)
    precondition(SystemMenuItem.match(identifier: "com.apple.menuextra.controlcenter", label: "Control Centre", owner: "com.apple.MenuBarAgent") == nil)
    precondition(SystemMenuItem.match(identifier: "com.apple.menuextra.wifi", label: "Wi-Fi", owner: "dev.unrelated") == nil)
}

func iconRastersKeepGlyphsWithoutBackgroundTiles() {
    precondition(MenuIconRaster.normalize(rasterFixture(background: [0,0,0,0], foreground: nil)) == nil)
    guard let white = MenuIconRaster.normalize(rasterFixture(background: [30,30,30,255], foreground: [255,255,255,255])),
          let provider = white.image.dataProvider, let data = provider.data else { fatalError("Missing white glyph") }
    let bytes = data as Data
    precondition(white.isTemplate && white.image.width < 24 && white.image.height < 24)
    precondition(bytes[3] == 0 && bytes.contains(255))
    guard let red = MenuIconRaster.normalize(rasterFixture(background: [0,0,0,0], foreground: [255,0,0,255])) else {
        fatalError("Missing colored glyph")
    }
    precondition(!red.isTemplate)
}

@main enum TuckChecks {
    static func main() throws {
        selectedAppsAreHiddenWhileOtherAppsAndHostStayReachable()
        temporaryActivationOnlyRevealsTheSelectedPocketApp()
        stalePreferencesCannotHideTuckOrSystemApps()
        disabledSelectionAndNewlyLaunchedAppsRemainVisible()
        try savedSelectionsRoundTripWithoutDuplicates()
        try earlierHidePreferencesMigrate()
        try pocketTracksRunningOwnersWithoutDiscardingSavedRules()
        draggingChangesOnlyTheChosenAppsGroup()
        try movingAnIconBeforeAnotherPreservesItsSavedOrder()
        repeatedMovesNeverDuplicateAnIcon()
        protectedIconsCannotBeDraggedIntoHiddenGroups()
        let apps = [TuckedApp(id: "dev.always", name: "Always", path: "", visibility: .show),
                    TuckedApp(id: "dev.pocket", name: "Pocket", path: "", visibility: .hide),
                    TuckedApp(id: "dev.never", name: "Never", path: "", visibility: .neverShow)]
        precondition(VisibilityPolicy.pocketApps(apps, host: "dev.tuck").map(\.id) == ["dev.pocket"])
        precondition(VisibilityPolicy.suppressedBundles(apps: apps, host: "dev.tuck") == ["dev.pocket", "dev.never"])
        for style in PocketStyle.allCases {
            let saved = try JSONDecoder().decode(PocketStyle.self, from: JSONEncoder().encode(style))
            precondition(saved == style)
        }
        let bar = CGRect(x: 1512, y: 0, width: 1512, height: 33)
        precondition(IconCropGeometry.pixels(item: CGRect(x: 1600, y: 4.5, width: 24, height: 24), capture: bar, scale: 2)
            == CGRect(x: 176, y: 9, width: 48, height: 48))
        precondition(IconCropGeometry.pixels(item: CGRect(x: 1510, y: 4, width: 24, height: 24), capture: bar, scale: 2) == nil)
        precondition(IconCropGeometry.pixels(item: CGRect(x: 1600, y: 4, width: 24, height: 24), capture: bar, scale: 0) == nil)
        iconRastersKeepGlyphsWithoutBackgroundTiles()
        clippedNeighborsAreRemovedWithoutErasingGlyphParts()
        try systemIconsHaveIndependentRulesAndProtectedControls()
        systemHelperRulesDoNotHideOtherAppleControls()
        systemDiscoveryUsesNativeIdentifiersAndKnownHelpers()
        try menuLayoutsKeepAnImmovableCaret()
        try discoveryTucksNewIconsAndPreservesSavedChoices()
        notificationCenterShortcutsRespectSystemOverrides()
        print("PASS: visibility, discovery, row order, fixed caret, system-item, Pocket, persistence, shortcut and icon-image checks")
    }
}
