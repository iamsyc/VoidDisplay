@testable import VoidDisplayApp
import CoreGraphics
import Testing

@Suite
struct HomeSummaryDistributedLayoutTests {
    @Test func distributesAllItemsAcrossOneWideRow() {
        let layout = makeLayout()
        let sizes = itemSizes(widths: [80, 70, 60, 50, 50])

        let plan = layout.layoutPlan(for: 470, sizes: sizes)

        #expect(plan.rows.count == 1)
        #expect(plan.rows[0].range.lowerBound == 0)
        #expect(plan.rows[0].range.upperBound == 5)
        expectClose(plan.rows[0].distributedGap(in: 470, minimumColumnSpacing: 10), to: 40)
        expectClose(plan.size(width: 470).width, to: 470)
        expectClose(plan.size(width: 470).height, to: 20)
    }

    @Test func splitsPrimaryAndSecondaryRowsAndDistributesBothRows() {
        let layout = makeLayout()
        let sizes = itemSizes(widths: [80, 70, 60, 50, 60, 70, 100, 80])

        let plan = layout.layoutPlan(for: 430, sizes: sizes)

        #expect(plan.rows.count == 2)
        #expect(plan.rows[0].range.lowerBound == 0)
        #expect(plan.rows[0].range.upperBound == 3)
        #expect(plan.rows[1].range.lowerBound == 3)
        #expect(plan.rows[1].range.upperBound == 8)
        expectClose(plan.rows[0].distributedGap(in: 430, minimumColumnSpacing: 10), to: 110)
        expectClose(plan.rows[1].distributedGap(in: 430, minimumColumnSpacing: 10), to: 17.5)
        expectClose(plan.size(width: 430).height, to: 48)
    }

    @Test func greedilyWrapsRowsThatCannotFitAsAGroup() {
        let layout = makeLayout()
        let sizes = itemSizes(widths: [70, 70, 70, 120, 120, 80])

        let plan = layout.layoutPlan(for: 230, sizes: sizes)

        #expect(plan.rows.count == 3)
        #expect(plan.rows[0].range.lowerBound == 0)
        #expect(plan.rows[0].range.upperBound == 3)
        #expect(plan.rows[1].range.lowerBound == 3)
        #expect(plan.rows[1].range.upperBound == 4)
        #expect(plan.rows[2].range.lowerBound == 4)
        #expect(plan.rows[2].range.upperBound == 6)
        expectClose(plan.rows[0].distributedGap(in: 230, minimumColumnSpacing: 10), to: 10)
        expectClose(plan.rows[2].distributedGap(in: 230, minimumColumnSpacing: 10), to: 30)
    }

    @Test func reportsNaturalPackedWidthWithoutAWidthProposal() {
        let layout = makeLayout()
        let sizes = itemSizes(widths: [80, 70, 60])

        let plan = layout.layoutPlan(for: nil, sizes: sizes)

        #expect(plan.rows.count == 1)
        expectClose(plan.size(width: nil).width, to: 230)
    }

    private func makeLayout() -> HomeSummaryDistributedLayout {
        HomeSummaryDistributedLayout(
            primaryItemCount: 3,
            minimumColumnSpacing: 10,
            rowSpacing: 8
        )
    }

    private func itemSizes(widths: [CGFloat]) -> [CGSize] {
        widths.map { CGSize(width: $0, height: 20) }
    }

    private func expectClose(_ value: CGFloat, to expected: CGFloat) {
        #expect(abs(value - expected) < 0.001)
    }
}
