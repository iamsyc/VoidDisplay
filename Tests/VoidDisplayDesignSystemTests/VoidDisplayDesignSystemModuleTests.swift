import Testing
import SwiftUI
@testable import VoidDisplayDesignSystem

@Suite("VoidDisplayDesignSystem module")
struct VoidDisplayDesignSystemModuleTests {
    @Test func moduleLoads() {
        #expect(Bool(true))
    }

    @Test func appSkinIDsExposeStableBuiltInOrder() {
        #expect(AppSkinID.allCases == [.classic, .compact, .dashboard])
    }

    @Test func appThemeDensityMatchesSkinIntent() {
        let classic = AppTheme.resolve(skinID: .classic, colorScheme: .light).density
        let compact = AppTheme.resolve(skinID: .compact, colorScheme: .light).density
        let dashboard = AppTheme.resolve(skinID: .dashboard, colorScheme: .light).density

        #expect(compact.cardVerticalPadding < classic.cardVerticalPadding)
        #expect(compact.contentMaxWidth > classic.contentMaxWidth)
        #expect(dashboard.cardCornerRadius > classic.cardCornerRadius)
    }
}
