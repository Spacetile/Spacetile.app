import CoreGraphics

/// A window server window number (`CGWindowID`).
public typealias WindowID = UInt32

/// Screen coordinates throughout Core are top-left origin with y growing down,
/// matching the Accessibility API, so `north` means smaller y.
public enum Direction: CaseIterable, Sendable {
    case west, east, north, south

    public var axis: Axis {
        switch self {
        case .west, .east: .horizontal
        case .north, .south: .vertical
        }
    }

    /// West and north are the leading side of their axis.
    public var isLeading: Bool { self == .west || self == .north }
}

/// The axis a split divides along: `horizontal` places children side by side.
public enum Axis: String, Codable, Sendable {
    case horizontal, vertical

    public var flipped: Axis { self == .horizontal ? .vertical : .horizontal }
}

extension CGRect {
    func length(along axis: Axis) -> CGFloat { axis == .horizontal ? width : height }

    /// Splits into two rects along `axis`, `gap` apart, the first taking `ratio` of the remaining length.
    func split(along axis: Axis, ratio: Double, gap: CGFloat) -> (CGRect, CGRect) {
        let firstLength = ((length(along: axis) - gap) * ratio).rounded()
        switch axis {
        case .horizontal:
            let first = CGRect(x: minX, y: minY, width: firstLength, height: height)
            let second = CGRect(x: first.maxX + gap, y: minY, width: maxX - first.maxX - gap, height: height)
            return (first, second)
        case .vertical:
            let first = CGRect(x: minX, y: minY, width: width, height: firstLength)
            let second = CGRect(x: minX, y: first.maxY + gap, width: width, height: maxY - first.maxY - gap)
            return (first, second)
        }
    }
}
