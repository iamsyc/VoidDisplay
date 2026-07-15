import SwiftUI

struct HomeSummaryDistributedLayout: Layout {
    let primaryItemCount: Int
    let minimumColumnSpacing: CGFloat
    let rowSpacing: CGFloat

    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: measuredSizes(subviews))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = measuredSizes(subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if cache.sizes.count != subviews.count {
            updateCache(&cache, subviews: subviews)
        }

        let plan = layoutPlan(for: proposal.width, sizes: cache.sizes)
        return plan.size(width: proposal.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.sizes.count != subviews.count {
            updateCache(&cache, subviews: subviews)
        }

        let plan = layoutPlan(for: bounds.width, sizes: cache.sizes)
        var y = bounds.minY

        for row in plan.rows {
            let gap = row.distributedGap(in: bounds.width, minimumColumnSpacing: minimumColumnSpacing)
            var x = bounds.minX

            for index in row.range {
                let size = cache.sizes[index]
                let point = CGPoint(x: x, y: y + max(0, (row.height - size.height) / 2))
                subviews[index].place(
                    at: point,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + (index == row.range.upperBound - 1 ? 0 : gap)
            }

            y += row.height + rowSpacing
        }
    }

    func layoutPlan(for availableWidth: CGFloat?, sizes: [CGSize]) -> HomeSummaryDistributedLayoutPlan {
        guard !sizes.isEmpty else {
            return HomeSummaryDistributedLayoutPlan(rows: [], naturalWidth: 0, rowSpacing: rowSpacing)
        }

        let naturalWidth = packedWidth(0..<sizes.count, sizes: sizes)
        let width = normalizedAvailableWidth(availableWidth, fallback: naturalWidth)
        let rows = rowRanges(for: width, sizes: sizes).map { range in
            HomeSummaryDistributedLayoutRow(
                range: range,
                contentWidth: contentWidth(range, sizes: sizes),
                height: range.map { sizes[$0].height }.max() ?? 0
            )
        }

        return HomeSummaryDistributedLayoutPlan(rows: rows, naturalWidth: naturalWidth, rowSpacing: rowSpacing)
    }

    private func measuredSizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    private func rowRanges(for availableWidth: CGFloat, sizes: [CGSize]) -> [Range<Int>] {
        let allItems = 0..<sizes.count

        if packedWidth(allItems, sizes: sizes) <= availableWidth {
            return [allItems]
        }

        let primaryEnd = min(max(0, primaryItemCount), sizes.count)
        guard primaryEnd > 0 else {
            return greedyRanges(in: allItems, availableWidth: availableWidth, sizes: sizes)
        }

        var ranges: [Range<Int>] = []
        let primaryRange = 0..<primaryEnd
        if packedWidth(primaryRange, sizes: sizes) <= availableWidth {
            ranges.append(primaryRange)
        } else {
            ranges.append(contentsOf: greedyRanges(in: primaryRange, availableWidth: availableWidth, sizes: sizes))
        }

        let secondaryRange = primaryEnd..<sizes.count
        if !secondaryRange.isEmpty {
            if packedWidth(secondaryRange, sizes: sizes) <= availableWidth {
                ranges.append(secondaryRange)
            } else {
                ranges.append(contentsOf: greedyRanges(in: secondaryRange, availableWidth: availableWidth, sizes: sizes))
            }
        }

        return ranges
    }

    private func greedyRanges(in range: Range<Int>, availableWidth: CGFloat, sizes: [CGSize]) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var rowStart = range.lowerBound
        var rowWidth: CGFloat = 0

        for index in range {
            let itemWidth = sizes[index].width
            let nextWidth = rowStart == index ? itemWidth : rowWidth + minimumColumnSpacing + itemWidth

            if index > rowStart, nextWidth > availableWidth {
                rows.append(rowStart..<index)
                rowStart = index
                rowWidth = itemWidth
            } else {
                rowWidth = nextWidth
            }
        }

        if rowStart < range.upperBound {
            rows.append(rowStart..<range.upperBound)
        }

        return rows
    }

    private func packedWidth(_ range: Range<Int>, sizes: [CGSize]) -> CGFloat {
        contentWidth(range, sizes: sizes) + minimumColumnSpacing * CGFloat(max(0, range.count - 1))
    }

    private func contentWidth(_ range: Range<Int>, sizes: [CGSize]) -> CGFloat {
        range.reduce(0) { $0 + sizes[$1].width }
    }

    private func normalizedAvailableWidth(_ width: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let width, width.isFinite, width > 0 else {
            return fallback
        }
        return width
    }
}

struct HomeSummaryDistributedLayoutPlan {
    let rows: [HomeSummaryDistributedLayoutRow]
    let naturalWidth: CGFloat
    let rowSpacing: CGFloat

    func size(width proposedWidth: CGFloat?) -> CGSize {
        guard !rows.isEmpty else {
            return .zero
        }

        let height = rows.reduce(0) { $0 + $1.height }
            + rowSpacing * CGFloat(max(0, rows.count - 1))
        let width = proposedWidth ?? naturalWidth

        return CGSize(width: width, height: height)
    }
}

struct HomeSummaryDistributedLayoutRow {
    let range: Range<Int>
    let contentWidth: CGFloat
    let height: CGFloat

    func distributedGap(in availableWidth: CGFloat, minimumColumnSpacing: CGFloat) -> CGFloat {
        guard range.count > 1 else {
            return 0
        }

        let availableGap = availableWidth - contentWidth
        return max(minimumColumnSpacing, availableGap / CGFloat(range.count - 1))
    }
}
