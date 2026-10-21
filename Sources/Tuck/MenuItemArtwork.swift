import AppKit
import SwiftUI
import TuckCore

struct MenuItemArtwork: View {
    let app: TuckedApp
    let size: CGFloat
    var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: min(image.size.width, max(size, 28)), height: min(image.size.height, size))
            } else if let system = app.systemItem {
                Image(systemName: system.symbol).resizable().scaledToFit().frame(width: size, height: size)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().scaledToFit().frame(width: size, height: size)
            }
        }
    }
}
