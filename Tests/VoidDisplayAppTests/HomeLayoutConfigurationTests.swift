@testable import VoidDisplayApp
import Testing
import VoidDisplayDesignSystem

struct HomeLayoutConfigurationTests {
    @Test func listConfigurationOwnsCurrentHomeSurfaceMetrics() {
        let list = HomeLayoutConfiguration.list

        #expect(list.metrics.itemHorizontalPadding == AppUI.Spacing.large)
        #expect(list.metrics.itemVerticalPadding == AppUI.Spacing.medium)
        #expect(list.metrics.itemCornerRadius == 8)
        #expect(list.metrics.itemSpacing == AppUI.List.sectionSpacing)
        #expect(list.metrics.contentMaxWidth == 1240)
    }
}
