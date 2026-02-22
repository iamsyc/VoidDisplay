import Testing
@testable import VoidDisplay

struct VirtualDisplayRowPresentationTests {

    @Test func subtitleUsesSerialAndMaxMode() {
        let config = VirtualDisplayConfig(
            name: "Display",
            serialNum: 12,
            physicalWidth: 310,
            physicalHeight: 174,
            modes: [
                .init(width: 1280, height: 720, refreshRate: 60, enableHiDPI: false),
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )

        let subtitle = VirtualDisplayRowPresentation.subtitleText(for: config)
        #expect(subtitle.contains("12"))
        #expect(subtitle.contains("1920 × 1080"))
        #expect(subtitle.contains("•"))
    }

    @Test func badgesIncludeAppliedAndFailureTags() {
        let plain = VirtualDisplayRowPresentation.badges(
            rebuildFailureMessage: nil,
            hasRecentApplySuccess: false
        )
        #expect(plain.count == 1)
        #expect(plain.first?.title == String(localized: "Virtual Display"))

        let appliedAndFailed = VirtualDisplayRowPresentation.badges(
            rebuildFailureMessage: "boom",
            hasRecentApplySuccess: true
        )
        #expect(appliedAndFailed.count == 3)
        #expect(appliedAndFailed.map(\.title).contains(String(localized: "Applied")))
        #expect(appliedAndFailed.map(\.title).contains(String(localized: "Rebuild failed")))
    }

    @Test func restoreFailureSummaryTruncatesWithEllipsis() {
        let failures = [
            VirtualDisplayRestoreFailure(id: UUID(), name: "A", serialNum: 1, message: "m1"),
            VirtualDisplayRestoreFailure(id: UUID(), name: "B", serialNum: 2, message: "m2"),
            VirtualDisplayRestoreFailure(id: UUID(), name: "C", serialNum: 3, message: "m3"),
            VirtualDisplayRestoreFailure(id: UUID(), name: "D", serialNum: 4, message: "m4")
        ]

        let summary = VirtualDisplayRowPresentation.restoreFailureSummary(failures)
        #expect(summary.contains("A (Serial 1): m1"))
        #expect(summary.contains("C (Serial 3): m3"))
        #expect(summary.contains("…"))
        #expect(summary.contains("D (Serial 4): m4") == false)
    }
}
