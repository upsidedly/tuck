import AppKit
import CryptoKit
import ImageIO
import ScreenCaptureKit
import TuckCore
import UniformTypeIdentifiers
import os

struct MenuGlyphRecord: Codable, Sendable {
    let key: String
    let owner: String
    let label: String
    let width: Double
    let height: Double
    let isTemplate: Bool
    let filename: String
}

struct MenuGlyphData: Sendable {
    let record: MenuGlyphRecord
    let png: Data
}

struct PocketItem: Identifiable {
    let app: TuckedApp
    let glyph: MenuGlyphRecord?
    let image: NSImage?
    var id: String { glyph?.key ?? app.id }
    var label: String { glyph?.label ?? app.name }
    @MainActor var width: CGFloat { image.map { max(28, min($0.size.width + 12, 180)) } ?? 32 }
}

enum MenuGlyphError: LocalizedError {
    case noDisplay, unavailable
    var errorDescription: String? {
        switch self {
        case .noDisplay: "The menu bar display is unavailable."
        case .unavailable: "Couldn’t capture this menu icon. Use Refresh Icons to try again."
        }
    }
}

/// Only the menu-bar strip is captured. Full-screen images are never captured
/// or saved; persistent files contain individual, tightly cropped icons.
actor MenuGlyphStore {
    private let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support/Tuck/MenuIcons", isDirectory: true)
    private var index: [MenuGlyphRecord]?
    private let logger = Logger(subsystem: "dev.matthew.tuck", category: "MenuIcons")

    func load() -> [MenuGlyphData] {
        loadIndex().compactMap { record in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(record.filename)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let normalized = MenuIconRaster.normalize(original), record.width > 0,
                  let png = Self.png(normalized.image) else { return nil }
            let scale = Double(original.width) / record.width
            let corrected = MenuGlyphRecord(key: record.key, owner: record.owner, label: record.label,
                width: Double(normalized.image.width) / scale, height: Double(normalized.image.height) / scale,
                isTemplate: normalized.isTemplate, filename: record.filename)
            return MenuGlyphData(record: corrected, png: png)
        }
    }

    func capture(owner: String, items: [MenuIcon], screen: CGRect, barHeight: CGFloat, scale: CGFloat) async throws -> [MenuGlyphData] {
        guard #available(macOS 14.2, *) else { throw MenuGlyphError.unavailable }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.frame.intersects(screen) }) else { throw MenuGlyphError.noDisplay }
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" &&
            $0.frame.height <= 80 && $0.frame.intersects(display.frame)
        }
        let filter = SCContentFilter(display: display, including: windows)
        filter.includeMenuBar = true
        let captureRect = CGRect(x: display.frame.minX, y: display.frame.minY,
                                 width: display.frame.width, height: barHeight)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(origin: .zero, size: captureRect.size)
        configuration.width = Int(captureRect.width * scale)
        configuration.height = Int(captureRect.height * scale)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        var result: [MenuGlyphData] = []
        for (ordinal, item) in items.enumerated() {
            guard let frame = item.frame,
                  let rect = IconCropGeometry.pixels(item: frame, capture: captureRect, scale: scale),
                  let crop = strip.cropping(to: rect), let normalized = MenuIconRaster.normalize(crop) else { continue }
            let fields = item.id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            let identifier = fields.count > 1 && !fields[1].isEmpty ? String(fields[1]) : "item-\(ordinal)"
            let key = owner + "|" + identifier
            let filename = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
            guard let data = Self.png(normalized.image) else { continue }
            let record = MenuGlyphRecord(key: key, owner: owner, label: item.label,
                width: Double(normalized.image.width) / scale, height: Double(normalized.image.height) / scale,
                isTemplate: normalized.isTemplate, filename: filename)
            result.append(MenuGlyphData(record: record, png: data))
        }
        guard !result.isEmpty else { throw MenuGlyphError.unavailable }
        save(result, owner: owner)
        return result
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func loadIndex() -> [MenuGlyphRecord] {
        if let index { return index }
        let records = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode([MenuGlyphRecord].self, from: $0) } ?? []
        index = records
        return records
    }

    private func save(_ values: [MenuGlyphData], owner: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for value in values { try value.png.write(to: directory.appendingPathComponent(value.record.filename), options: .atomic) }
            let previous = loadIndex()
            let records = Array((previous.filter { $0.owner != owner } + values.map(\.record)).suffix(256))
            try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            index = records
            let retained = Set(records.map(\.filename))
            for obsolete in previous where !retained.contains(obsolete.filename) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(obsolete.filename))
            }
        } catch { logger.error("Could not save menu-icon cache: \(error.localizedDescription, privacy: .public)") }
    }

}
