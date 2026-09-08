@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import Testing

@MainActor
struct CreateVirtualDisplayInputValidatorTests {

    @Test func addPresetModeAppendsOrDetectsDuplicate() {
        let initial: [ResolutionSelection] = []

        let first = CreateVirtualDisplayInputValidator.addPresetMode(
            preset: .w1920h1080,
            to: initial
        )
        guard case .appended(let withPreset) = first else {
            Issue.record("Expected appended preset")
            return
        }
        #expect(withPreset.count == 1)

        let duplicate = CreateVirtualDisplayInputValidator.addPresetMode(
            preset: .w1920h1080,
            to: withPreset
        )
        guard case .duplicate = duplicate else {
            Issue.record("Expected duplicate")
            return
        }
    }

    @Test func addCustomModeValidatesAndDeduplicates() {
        let invalid = CreateVirtualDisplayInputValidator.addCustomMode(
            width: 0,
            height: 1080,
            refreshRate: 60,
            to: []
        )
        guard case .invalidValues = invalid else {
            Issue.record("Expected invalid values")
            return
        }

        let first = CreateVirtualDisplayInputValidator.addCustomMode(
            width: 2560,
            height: 1440,
            refreshRate: 60,
            to: []
        )
        guard case .appended(let appended) = first else {
            Issue.record("Expected appended custom mode")
            return
        }
        #expect(appended.count == 1)

        let duplicate = CreateVirtualDisplayInputValidator.addCustomMode(
            width: 2560,
            height: 1440,
            refreshRate: 60,
            to: appended
        )
        guard case .duplicate = duplicate else {
            Issue.record("Expected duplicate custom mode")
            return
        }

        let tooLarge = CreateVirtualDisplayInputValidator.addCustomMode(
            width: 9000,
            height: 2160,
            refreshRate: 60,
            to: appended
        )
        guard case .invalidValues = tooLarge else {
            Issue.record("Expected invalid values for oversize custom mode")
            return
        }

        let invalidRefreshRate = CreateVirtualDisplayInputValidator.addCustomMode(
            width: 1920,
            height: 1080,
            refreshRate: .infinity,
            to: appended
        )
        guard case .invalidValues = invalidRefreshRate else {
            Issue.record("Expected invalid values for non-finite refresh rate")
            return
        }
    }

    @Test func maxPixelDimensionsReflectsHiDPIAndRejectsInvalidValues() {
        let empty = CreateVirtualDisplayInputValidator.maxPixelDimensions(for: [])
        #expect(empty == .invalidValues)

        let normal = CreateVirtualDisplayInputValidator.maxPixelDimensions(
            for: [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: false)]
        )
        #expect(normal == .resolved(width: 2560, height: 1440))

        let hiDPI = CreateVirtualDisplayInputValidator.maxPixelDimensions(
            for: [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)]
        )
        #expect(hiDPI == .resolved(width: 5120, height: 2880))

        let oversizedHiDPI = CreateVirtualDisplayInputValidator.maxPixelDimensions(
            for: [.init(width: 5000, height: 3000, refreshRate: 60, enableHiDPI: true)]
        )
        #expect(oversizedHiDPI == .invalidValues)
    }

    @Test func initializeNameAndSerialUsesDefaultOnlyForUntouchedBaseName() {
        let base = String(localized: "Virtual Display")

        let untouched = CreateVirtualDisplayInputValidator.initializeNameAndSerial(
            currentName: base,
            baseName: base,
            nextSerial: 5
        )
        #expect(untouched.serialNum == 5)
        #expect(untouched.name == "\(base) 5")

        let customized = CreateVirtualDisplayInputValidator.initializeNameAndSerial(
            currentName: "Custom Name",
            baseName: base,
            nextSerial: 8
        )
        #expect(customized.serialNum == 8)
        #expect(customized.name == "Custom Name")
    }

    @Test func maxPixelDimensionsRejectsEveryInvalidMode() {
        let valid = ResolutionSelection(width: 1920, height: 1080, enableHiDPI: false)
        let invalidModes: [ResolutionSelection] = [
            .init(width: 0, height: 1080),
            .init(width: -1, height: 1080),
            .init(width: 1920, height: 0),
            .init(width: Int.max, height: Int.max),
            .init(width: 8193, height: 1, enableHiDPI: false),
            .init(width: 1, height: 4097, enableHiDPI: true),
            .init(width: 1920, height: 1080, refreshRate: 0),
            .init(width: 1920, height: 1080, refreshRate: -.infinity),
            .init(width: 1920, height: 1080, refreshRate: .nan)
        ]
        for invalid in invalidModes {
            #expect(CreateVirtualDisplayInputValidator.maxPixelDimensions(for: [valid, invalid]) == .invalidValues)
        }
    }

    @Test func customModeCanBeAddedBeforeTurningOffHiDPI() {
        let result = CreateVirtualDisplayInputValidator.addCustomMode(
            width: 8192, height: 8192, refreshRate: 60, to: []
        )
        guard case .appended(var modes) = result else {
            Issue.record("Expected a logical size within the limit to be editable")
            return
        }
        #expect(CreateVirtualDisplayInputValidator.maxPixelDimensions(for: modes) == .invalidValues)
        modes[0].enableHiDPI = false
        #expect(CreateVirtualDisplayInputValidator.maxPixelDimensions(for: modes) == .resolved(width: 8192, height: 8192))
    }
}
