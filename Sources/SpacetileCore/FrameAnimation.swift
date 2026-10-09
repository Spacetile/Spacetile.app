import CoreGraphics

/// The frames between where windows are and where a layout puts them. Accessibility can only set a
/// frame, so a re-tile animates by writing these one step at a time, as Glide and rift do.
public struct FrameAnimation: Sendable {
    /// Start and end of each window that moves; windows already in place aren't written.
    public let moves: [WindowID: (from: CGRect, to: CGRect)]

    /// Long enough to follow a window, short enough that tiling doesn't feel slow.
    public static let duration = 0.15

    public init(from start: [WindowID: CGRect], to end: [WindowID: CGRect]) {
        var moves: [WindowID: (from: CGRect, to: CGRect)] = [:]
        for (id, target) in end {
            guard let origin = start[id], origin.integral != target.integral else { continue }
            moves[id] = (origin, target)
        }
        self.moves = moves
    }

    public var isEmpty: Bool { moves.isEmpty }

    /// Every moving window's frame `progress` (0...1) of the way through, eased.
    public func frames(at progress: Double) -> [WindowID: CGRect] {
        let t = CGFloat(Self.ease(progress))
        return moves.mapValues { move in
            CGRect(x: move.from.minX + (move.to.minX - move.from.minX) * t,
                   y: move.from.minY + (move.to.minY - move.from.minY) * t,
                   width: move.from.width + (move.to.width - move.from.width) * t,
                   height: move.from.height + (move.to.height - move.from.height) * t).integral
        }
    }

    /// Cubic ease-out: quick to start, so a key press answers at once, and settling into place.
    public static func ease(_ progress: Double) -> Double {
        let p = 1 - min(max(progress, 0), 1)
        return 1 - p * p * p
    }
}
