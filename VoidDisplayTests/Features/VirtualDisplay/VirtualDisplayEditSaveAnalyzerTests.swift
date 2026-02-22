import Foundation
import Testing
@testable import VoidDisplay

struct VirtualDisplayEditSaveAnalyzerTests {

    @Test func analyzeReturnsConfigNotFoundWhenOriginalMissing() {
        let draft = makeDraft()
        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: nil,
            configId: UUID(),
            draft: draft,
            existingConfigs: [],
            isRunning: false
        )

        guard case .failure(.configNotFound) = result else {
            Issue.record("Expected configNotFound")
            return
        }
    }

    @Test func analyzeRejectsDuplicateSerialNumber() {
        let configId = UUID()
        let original = makeConfig(id: configId, serial: 7)
        let draft = makeDraft(serialNum: 9)
        let existing = [
            original,
            makeConfig(id: UUID(), serial: 9)
        ]

        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: original,
            configId: configId,
            draft: draft,
            existingConfigs: existing,
            isRunning: false
        )

        guard case .failure(.duplicateSerialNumber(9)) = result else {
            Issue.record("Expected duplicate serial error")
            return
        }
    }

    @Test func analyzeRejectsInvalidSerialAndScreenInputs() {
        let original = makeConfig()

        let invalidSerial = VirtualDisplayEditSaveAnalyzer.analyze(
            original: original,
            configId: original.id,
            draft: makeDraft(serialNum: 0),
            existingConfigs: [original],
            isRunning: false
        )
        guard case .failure(.invalidSerialNumber) = invalidSerial else {
            Issue.record("Expected invalid serial")
            return
        }

        let invalidScreen = VirtualDisplayEditSaveAnalyzer.analyze(
            original: original,
            configId: original.id,
            draft: makeDraft(screenDiagonal: 0),
            existingConfigs: [original],
            isRunning: false
        )
        guard case .failure(.invalidScreenSize) = invalidScreen else {
            Issue.record("Expected invalid screen size")
            return
        }
    }

    @Test func analyzeReturnsApplyImmediatelyWhenRunningWithoutRebuildChange() {
        let original = makeConfig(serial: 7)
        let draft = makeDraft(
            name: original.name,
            serialNum: Int(original.serialNum),
            selectedModes: original.resolutionModes,
            screenDiagonal: 14.0,
            selectedAspectRatio: .ratio_16_9,
            initialScreenDiagonal: 14.0,
            initialAspectRatio: .ratio_16_9
        )

        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: original,
            configId: original.id,
            draft: draft,
            existingConfigs: [original],
            isRunning: true
        )

        guard case .success(let analysis) = result else {
            Issue.record("Expected successful analysis")
            return
        }

        #expect(analysis.requiresSaveAndRebuild == false)
        #expect(analysis.shouldApplyModesImmediately)
        #expect(analysis.updatedConfig.serialNum == original.serialNum)
    }

    @Test func analyzeRequiresRebuildWhenMaxPixelsIncrease() {
        let original = makeConfig(
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ]
        )
        let draft = makeDraft(
            selectedModes: [
                .init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)
            ]
        )

        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: original,
            configId: original.id,
            draft: draft,
            existingConfigs: [original],
            isRunning: true
        )

        guard case .success(let analysis) = result else {
            Issue.record("Expected successful analysis")
            return
        }

        #expect(analysis.requiresSaveAndRebuild)
        #expect(analysis.shouldApplyModesImmediately == false)
        #expect(analysis.updatedConfig.maxPixelDimensions.width == 5120)
    }

    @Test func analyzeUpdatesPhysicalSizeWhenInputChanges() {
        let original = makeConfig(physicalWidth: 300, physicalHeight: 200)
        let draft = makeDraft(
            screenDiagonal: 16.0,
            selectedAspectRatio: .ratio_16_10,
            initialScreenDiagonal: 14.0,
            initialAspectRatio: .ratio_16_9
        )

        let result = VirtualDisplayEditSaveAnalyzer.analyze(
            original: original,
            configId: original.id,
            draft: draft,
            existingConfigs: [original],
            isRunning: false
        )

        guard case .success(let analysis) = result else {
            Issue.record("Expected successful analysis")
            return
        }

        #expect(analysis.updatedConfig.physicalWidth != original.physicalWidth)
        #expect(analysis.updatedConfig.physicalHeight != original.physicalHeight)
    }

    @Test func inferPhysicalInputsAndDisplayedPhysicalSizeFollowDraftChanges() {
        let config = makeConfig(physicalWidth: 310, physicalHeight: 174)

        let inferred = VirtualDisplayEditSaveAnalyzer.inferPhysicalInputs(from: config)
        #expect(inferred != nil)
        #expect(inferred?.aspectRatio == .ratio_16_9)

        let unchangedSize = VirtualDisplayEditSaveAnalyzer.displayedPhysicalSize(
            loadedConfig: config,
            draft: makeDraft(
                screenDiagonal: 14.0,
                selectedAspectRatio: .ratio_16_9,
                initialScreenDiagonal: 14.0,
                initialAspectRatio: .ratio_16_9
            )
        )
        #expect(unchangedSize.width == 310)
        #expect(unchangedSize.height == 174)

        let changedSize = VirtualDisplayEditSaveAnalyzer.displayedPhysicalSize(
            loadedConfig: config,
            draft: makeDraft(
                screenDiagonal: 16.0,
                selectedAspectRatio: .ratio_16_10,
                initialScreenDiagonal: 14.0,
                initialAspectRatio: .ratio_16_9
            )
        )
        #expect(changedSize.width != 310)
    }

    private func makeConfig(
        id: UUID = UUID(),
        name: String = "Display",
        serial: UInt32 = 7,
        physicalWidth: Int = 310,
        physicalHeight: Int = 174,
        modes: [VirtualDisplayConfig.ModeConfig] = [
            .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
        ]
    ) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: id,
            name: name,
            serialNum: serial,
            physicalWidth: physicalWidth,
            physicalHeight: physicalHeight,
            modes: modes,
            desiredEnabled: true
        )
    }

    private func makeDraft(
        name: String = "Updated",
        serialNum: Int = 7,
        selectedModes: [ResolutionSelection] = [
            .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
        ],
        screenDiagonal: Double = 14.0,
        selectedAspectRatio: AspectRatio = .ratio_16_9,
        initialScreenDiagonal: Double = 14.0,
        initialAspectRatio: AspectRatio = .ratio_16_9
    ) -> VirtualDisplayEditSaveAnalyzer.Draft {
        VirtualDisplayEditSaveAnalyzer.Draft(
            name: name,
            serialNum: serialNum,
            selectedModes: selectedModes,
            screenDiagonal: screenDiagonal,
            selectedAspectRatio: selectedAspectRatio,
            initialScreenDiagonal: initialScreenDiagonal,
            initialAspectRatio: initialAspectRatio
        )
    }
}
