import Foundation
import CoreGraphics

public enum MenuIconRaster {
    public static func normalize(_ image: CGImage) -> (image: CGImage, isTemplate: Bool)? {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let flags = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Display capture may composite a menu-bar background. Remove its local
        // vertical gradient using the empty top/bottom edge of each icon frame.
        let opaque = stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 250 }
        if opaque {
            for x in 0..<width {
                let top = (0..<3).map { Double(pixels[x * 4 + $0]) }
                let bottom = (0..<3).map { Double(pixels[((height - 1) * width + x) * 4 + $0]) }
                for y in 0..<height {
                    let offset = (y * width + x) * 4
                    let blend = Double(y) / Double(height - 1)
                    let background = (0..<3).map { top[$0] * (1 - blend) + bottom[$0] * blend }
                    let foreground = background.reduce(0,+) / 3 < 128 ? 255.0 : 0.0
                    let alpha = (0..<3).map { abs(Double(pixels[offset + $0]) - background[$0]) / max(32, abs(foreground - background[$0])) }.max() ?? 0
                    let a = alpha < 0.06 ? 0 : min(alpha, 1)
                    for channel in 0..<3 {
                        let color = a > 0 ? (Double(pixels[offset + channel]) - background[channel] * (1 - a)) / a : 0
                        pixels[offset + channel] = UInt8(max(0, min(255, color)) * a)
                    }
                    pixels[offset + 3] = UInt8(a * 255)
                }
            }
        }
        removeClippedEdgeFragments(&pixels, width: width, height: height)
        var minX = width, minY = height, maxX = 0, maxY = 0, visible = 0, monochrome = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard pixels[offset + 3] > 16 else { continue }
                visible += 1
                let r = Int(pixels[offset]), g = Int(pixels[offset+1]), b = Int(pixels[offset+2])
                if max(r,g,b) - min(r,g,b) < 15 { monochrome += 1 }
                minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y)
            }
        }
        guard visible > 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let processed = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: flags), provider: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent),
              let trimmed = processed.cropping(to: CGRect(x: minX-1, y: minY-1,
                  width: maxX-minX+3, height: maxY-minY+3).intersection(CGRect(x: 0,y: 0,width: width,height: height))) else { return nil }
        return (trimmed, Double(monochrome) / Double(visible) > 0.96)
    }

    /// Some hosted AX frames include a sliver of the adjacent item. Remove
    /// only small, disconnected pieces cut by a side of the capture frame.
    /// Interior dots, badges and separate parts of a glyph stay intact.
    private static func removeClippedEdgeFragments(_ pixels: inout [UInt8], width: Int, height: Int) {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [(indices: [Int], side: Bool, width: Int)] = []
        for start in visited.indices where !visited[start] && pixels[start * 4 + 3] > 16 {
            var queue = [start], cursor = 0, minX = width, maxX = 0
            var touchesSide = false
            visited[start] = true
            while cursor < queue.count {
                let index = queue[cursor], x = index % width, y = index / width
                cursor += 1
                minX = min(minX, x); maxX = max(maxX, x)
                touchesSide = touchesSide || x == 0 || x == width - 1
                for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = nextY * width + nextX
                        if !visited[next] && pixels[next * 4 + 3] > 16 {
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
            }
            components.append((queue, touchesSide, maxX - minX + 1))
        }
        let largest = components.map { $0.indices.count }.max() ?? 0
        for component in components where component.side && component.indices.count * 4 < largest && component.width <= max(3, width / 6) {
            for index in component.indices {
                for channel in 0..<4 { pixels[index * 4 + channel] = 0 }
            }
        }
    }
}
