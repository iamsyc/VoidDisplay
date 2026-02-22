import Foundation

struct VirtualDisplayEditSaveAnalyzer {
    struct Draft {
        var name: String
        var serialNum: Int
        var selectedModes: [ResolutionSelection]
        var screenDiagonal: Double
        var selectedAspectRatio: AspectRatio
        var initialScreenDiagonal: Double
        var initialAspectRatio: AspectRatio
    }

    struct SaveAnalysis {
        let updatedConfig: VirtualDisplayConfig
        let shouldApplyModesImmediately: Bool
        let requiresSaveAndRebuild: Bool
    }

    enum ValidationError: Error, Equatable {
        case configNotFound
        case emptyName
        case noResolutionModes
        case invalidSerialNumber
        case invalidScreenSize
        case duplicateSerialNumber(UInt32)
    }

    static func analyze(
        original: VirtualDisplayConfig?,
        configId: UUID,
        draft: Draft,
        existingConfigs: [VirtualDisplayConfig],
        isRunning: Bool
    ) -> Result<SaveAnalysis, ValidationError> {
        guard let original else {
            return .failure(.configNotFound)
        }

        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(.emptyName)
        }

        guard !draft.selectedModes.isEmpty else {
            return .failure(.noResolutionModes)
        }

        guard draft.serialNum > 0, draft.serialNum <= Int(UInt32.max) else {
            return .failure(.invalidSerialNumber)
        }

        guard draft.screenDiagonal > 0 else {
            return .failure(.invalidScreenSize)
        }

        let newSerial = UInt32(draft.serialNum)
        if existingConfigs.contains(where: { $0.id != configId && $0.serialNum == newSerial }) {
            return .failure(.duplicateSerialNumber(newSerial))
        }

        var updated = original
        updated.name = trimmedName
        updated.serialNum = newSerial
        updated.modes = draft.selectedModes.map {
            VirtualDisplayConfig.ModeConfig(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }

        if hasPhysicalInputsChanged(draft: draft) {
            let size = draft.selectedAspectRatio.sizeInMillimeters(diagonalInches: draft.screenDiagonal)
            updated.physicalWidth = size.width
            updated.physicalHeight = size.height
        }

        let newMaxPixels = updated.maxPixelDimensions
        let oldMaxPixels = original.maxPixelDimensions
        let requiresSaveAndRebuild = isRunning && (
            original.name != updated.name ||
            original.serialNum != updated.serialNum ||
            original.physicalWidth != updated.physicalWidth ||
            original.physicalHeight != updated.physicalHeight ||
            newMaxPixels.width > oldMaxPixels.width ||
            newMaxPixels.height > oldMaxPixels.height
        )

        return .success(
            SaveAnalysis(
                updatedConfig: updated,
                shouldApplyModesImmediately: isRunning && !requiresSaveAndRebuild,
                requiresSaveAndRebuild: requiresSaveAndRebuild
            )
        )
    }

    static func inferPhysicalInputs(
        from config: VirtualDisplayConfig
    ) -> (aspectRatio: AspectRatio, diagonalInches: Double)? {
        let physicalWidth = Double(config.physicalWidth)
        let physicalHeight = Double(config.physicalHeight)
        guard physicalWidth > 0, physicalHeight > 0 else {
            return nil
        }

        let inferredRatio = physicalWidth / physicalHeight
        let closestRatio = AspectRatio.allCases.min { lhs, rhs in
            let lhsGap = abs((lhs.components.width / lhs.components.height) - inferredRatio)
            let rhsGap = abs((rhs.components.width / rhs.components.height) - inferredRatio)
            return lhsGap < rhsGap
        } ?? .ratio_16_9

        let diagonal = sqrt((physicalWidth * physicalWidth) + (physicalHeight * physicalHeight)) / 25.4
        let rounded = (diagonal * 10).rounded() / 10
        return (closestRatio, rounded)
    }

    static func displayedPhysicalSize(
        loadedConfig: VirtualDisplayConfig?,
        draft: Draft
    ) -> (width: Int, height: Int) {
        guard let loadedConfig else {
            return draft.selectedAspectRatio.sizeInMillimeters(diagonalInches: draft.screenDiagonal)
        }

        guard hasPhysicalInputsChanged(draft: draft) else {
            return (loadedConfig.physicalWidth, loadedConfig.physicalHeight)
        }

        return draft.selectedAspectRatio.sizeInMillimeters(diagonalInches: draft.screenDiagonal)
    }

    private static func hasPhysicalInputsChanged(draft: Draft) -> Bool {
        abs(draft.screenDiagonal - draft.initialScreenDiagonal) >= 0.0001
            || draft.selectedAspectRatio != draft.initialAspectRatio
    }
}
