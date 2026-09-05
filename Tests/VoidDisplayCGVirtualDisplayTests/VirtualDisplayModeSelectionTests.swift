import Testing
@testable import VoidDisplayVirtualDisplayHost

@Suite("Virtual display current mode selection")
struct VirtualDisplayModeSelectionTests {
    @Test func replacesUnrequestedHalfSizeModeAfterDisablingHiDPI() {
        let halfSize = mode(id: 1, width: 960, height: 540)
        let fullSize = mode(id: 10)
        let selected = VirtualDisplayModeSelection.select(
            current: halfSize,
            available: [halfSize, fullSize],
            requested: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false)]
        )
        #expect(selected == fullSize)
    }

    @Test(arguments: [false, true])
    func distinguishesBackingPixelsForTheSameLogicalSize(hiDPI: Bool) {
        let standard = mode(id: 10)
        let retina = mode(id: 11, scale: 2)
        let selected = VirtualDisplayModeSelection.select(
            current: hiDPI ? standard : retina,
            available: [retina, standard],
            requested: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: hiDPI)]
        )
        #expect(selected == (hiDPI ? retina : standard))
    }

    @Test func preservesCurrentModeWhenItMatchesAnyConfiguredMode() {
        let first = mode(id: 10)
        let current = mode(id: 4, width: 1280, height: 720, scale: 2)
        let selected = VirtualDisplayModeSelection.select(
            current: current,
            available: [first, current],
            requested: [
                .init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false),
                .init(width: 1280, height: 720, refreshRate: 60, isHiDPI: true)
            ]
        )
        #expect(selected == current)
    }

    @Test func usesConfiguredOrderWhenCurrentModeIsUnavailable() {
        let first = mode(id: 10)
        let second = mode(id: 4, width: 1280, height: 720)
        let selected = VirtualDisplayModeSelection.select(
            current: nil,
            available: [second, first],
            requested: [
                .init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false),
                .init(width: 1280, height: 720, refreshRate: 60, isHiDPI: false)
            ]
        )
        #expect(selected == first)
    }

    @Test func selectsTheRequestedRefreshRate() {
        let wrongRate = mode(id: 10, refreshRate: 120)
        let requestedRate = mode(id: 11)
        let selected = VirtualDisplayModeSelection.select(
            current: wrongRate,
            available: [wrongRate, requestedRate],
            requested: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false)]
        )
        #expect(selected == requestedRate)
    }

    @Test(arguments: [(59.94, 60.0), (60.6, 61.0)])
    func matchesRefreshRatesRoundedByCoreGraphics(requested: Double, reported: Double) {
        let available = mode(id: 10, refreshRate: reported)
        let selected = VirtualDisplayModeSelection.select(
            current: nil,
            available: [available],
            requested: [.init(width: 1920, height: 1080, refreshRate: requested, isHiDPI: false)]
        )
        #expect(selected == available)
    }

    @Test func refusesAnUnconfiguredResolutionWhenNoModeMatches() {
        let halfSize = mode(id: 1, width: 960, height: 540)
        let selected = VirtualDisplayModeSelection.select(
            current: halfSize,
            available: [halfSize],
            requested: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false)]
        )
        #expect(selected == nil)
    }

    private func mode(
        id: Int32,
        width: Int = 1920,
        height: Int = 1080,
        scale: Int = 1,
        refreshRate: Double = 60
    ) -> VirtualDisplayModeSelection.Mode {
        .init(
            id: id,
            width: width,
            height: height,
            pixelWidth: width * scale,
            pixelHeight: height * scale,
            refreshRate: refreshRate
        )
    }
}
