import Foundation
import CoreGraphics

public enum IconCropGeometry {
    /// AX and screen-capture metadata both use top-left display coordinates.
    public static func pixels(item: CGRect, capture: CGRect, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale > 0, !item.isEmpty, !capture.isEmpty,
              item.minX.isFinite, item.minY.isFinite, item.width.isFinite, item.height.isFinite,
              capture.contains(item) else { return nil }
        return CGRect(x: (item.minX - capture.minX) * scale,
                      y: (item.minY - capture.minY) * scale,
                      width: item.width * scale, height: item.height * scale).integral
    }
}
