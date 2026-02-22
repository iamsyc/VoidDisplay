import Testing
@testable import VoidDisplay

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

    @Test func maxPixelDimensionsReflectsHiDPIAndFallback() {
        let fallback = CreateVirtualDisplayInputValidator.maxPixelDimensions(for: [])
        #expect(fallback.width == 1920)
        #expect(fallback.height == 1080)

        let normal = CreateVirtualDisplayInputValidator.maxPixelDimensions(
            for: [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: false)]
        )
        #expect(normal.width == 2560)
        #expect(normal.height == 1440)

        let hiDPI = CreateVirtualDisplayInputValidator.maxPixelDimensions(
            for: [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)]
        )
        #expect(hiDPI.width == 5120)
        #expect(hiDPI.height == 2880)

        let oversizedHiDPI = CreateVirtualDisplayInputValidator.maxPixelDimensions(
            for: [.init(width: 5000, height: 3000, refreshRate: 60, enableHiDPI: true)]
        )
        #expect(oversizedHiDPI.width == 1920)
        #expect(oversizedHiDPI.height == 1080)
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
}
