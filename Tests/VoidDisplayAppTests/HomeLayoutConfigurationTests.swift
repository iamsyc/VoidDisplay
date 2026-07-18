@testable import VoidDisplayApp
import Testing
import VoidDisplayDesignSystem

struct HomeLayoutMetricsTests {
    @Test func currentMetricsOwnHomeSurfaceSpacing() {
        let metrics = HomeLayoutMetrics.current

        #expect(metrics.itemHorizontalPadding == AppUI.Spacing.large)
        #expect(metrics.itemVerticalPadding == AppUI.Spacing.medium)
        #expect(metrics.itemCornerRadius == 8)
        #expect(metrics.itemSpacing == AppUI.List.sectionSpacing)
        #expect(metrics.contentMaxWidth == 1240)
    }
}
