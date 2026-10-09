import SwiftUI

/// Lays children out left to right at their natural size, wrapping to a new row when the next
/// one doesn't fit. Each row's children are centred on its height.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// Once children wrap, spread each row's out to fill the width, so both edges line up. A short
    /// last row keeps the gap of the row above, staying in its columns.
    var justified = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        if justified, rows.count > 1, let full = proposal.width, full.isFinite { return CGSize(width: full, height: height) }
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let rows = arrange(subviews, width: bounds.width)
        var gap = spacing
        for (index, row) in rows.enumerated() {
            if justified, rows.count > 1, row.count > 1, index < rows.count - 1 || row.count == rows[0].count {
                gap = (bounds.width - row.reduce(0) { $0 + $1.size.width }) / CGFloat(row.count - 1)
            }
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + gap
            }
            y += height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[(view: LayoutSubview, size: CGSize)]] {
        var rows: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((view, size))
            x += size.width + spacing
        }
        return rows
    }
}
