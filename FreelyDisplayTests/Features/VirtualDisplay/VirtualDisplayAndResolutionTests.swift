//
//  FreelyDisplayTests.swift
//  FreelyDisplayTests
//
//  Created by Phineas Guo on 2025/10/4.
//

import Testing
import Foundation
@testable import FreelyDisplay

struct VirtualDisplayAndResolutionTests {

    @Test func resolutionsParsing() {
        let res = Resolutions.r_1920_1080.resolutions
        #expect(res.0 == 1920)
        #expect(res.1 == 1080)
    }

    @Test func aspectRatioSizeInMillimeters() {
        let size = AspectRatio.ratio_16_9.sizeInMillimeters(diagonalInches: 14.0)
        #expect(size.width == 310)
        #expect(size.height == 174)
    }

    @Test func physicalPixelCalculation() {
        let hidpiPixels = DisplayCalculator.physicalPixels(logicalWidth: 1920, logicalHeight: 1080, hiDPI: true)
        #expect(hidpiPixels.width == 3840)
        #expect(hidpiPixels.height == 2160)

        let standardPixels = DisplayCalculator.physicalPixels(logicalWidth: 1920, logicalHeight: 1080, hiDPI: false)
        #expect(standardPixels.width == 1920)
        #expect(standardPixels.height == 1080)
    }

    @Test func resolutionSelectionHiDPIAndMatching() {
        let base = ResolutionSelection(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)
        let hidpi = base.hiDPIVersion()
        #expect(hidpi.width == 3840)
        #expect(hidpi.height == 2160)
        #expect(hidpi.enableHiDPI == false)

        let sameResolutionDifferentHiDPI = ResolutionSelection(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
        #expect(base.matchesResolution(of: sameResolutionDifferentHiDPI))
    }

    @Test func maxPixelDimensionsWithoutHiDPI() {
        let config = VirtualDisplayConfig(
            name: "No HiDPI",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1280, height: 800, refreshRate: 60, enableHiDPI: false),
                .init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )

        let maxPixels = config.maxPixelDimensions
        #expect(maxPixels.width == 2560)
        #expect(maxPixels.height == 1440)
    }

    @Test func maxPixelDimensionsWithHiDPI() {
        let config = VirtualDisplayConfig(
            name: "HiDPI",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1200, refreshRate: 60, enableHiDPI: false),
                .init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)
            ],
            desiredEnabled: true
        )

        let maxPixels = config.maxPixelDimensions
        #expect(maxPixels.width == 5120)
        #expect(maxPixels.height == 2880)
    }

    @Test func maxPixelDimensionsFallbackForEmptyModes() {
        let config = VirtualDisplayConfig(
            name: "Fallback",
            serialNum: 3,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [],
            desiredEnabled: true
        )

        let maxPixels = config.maxPixelDimensions
        #expect(maxPixels.width == 1920)
        #expect(maxPixels.height == 1080)
    }

    @MainActor @Test func decodingRequiresDesiredEnabledField() throws {
        let id = UUID().uuidString
        let json = """
        {
          "id": "\(id)",
          "name": "Strict Config",
          "serialNum": 7,
          "physicalWidth": 300,
          "physicalHeight": 200,
          "modes": [
            { "width": 1920, "height": 1080, "refreshRate": 60, "enableHiDPI": true }
          ],
          "isEnabled": false
        }
        """

        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(VirtualDisplayConfig.self, from: data)
        }
    }

    @MainActor @Test func codableRoundTripPreservesDesiredEnabled() throws {
        let original = VirtualDisplayConfig(
            name: "Round Trip",
            serialNum: 9,
            physicalWidth: 310,
            physicalHeight: 174,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)
            ],
            desiredEnabled: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VirtualDisplayConfig.self, from: encoded)
        #expect(decoded.desiredEnabled == false)
        #expect(decoded.serialNum == 9)
    }

    @MainActor @Test func virtualDisplayStoreFileFormatRoundTrip() throws {
        let config = VirtualDisplayConfig(
            name: "Stored Config",
            serialNum: 10,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)
            ],
            desiredEnabled: true
        )
        let original = VirtualDisplayStore.FileFormat(schemaVersion: 1, configs: [config])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VirtualDisplayStore.FileFormat.self, from: encoded)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.configs.count == 1)
        #expect(decoded.configs.first?.serialNum == 10)
        #expect(decoded.configs.first?.desiredEnabled == true)
    }

    @MainActor @Test func virtualDisplayStoreFileFormatPreservesSchemaVersion() throws {
        let original = VirtualDisplayStore.FileFormat(schemaVersion: 99, configs: [])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VirtualDisplayStore.FileFormat.self, from: encoded)
        #expect(decoded.schemaVersion == 99)
        #expect(decoded.configs.isEmpty)
    }

    @MainActor @Test func virtualDisplayStoreRejectsLegacyArrayFormat() throws {
        let config = VirtualDisplayConfig(
            name: "Legacy Array",
            serialNum: 42,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)],
            desiredEnabled: true
        )

        let data = try JSONEncoder().encode([config])
        #expect(throws: DecodingError.self) {
            _ = try VirtualDisplayStore().decodeConfigs(from: data)
        }
    }

    @MainActor @Test func virtualDisplayStoreSanitizesInvalidAndDuplicateConfigs() throws {
        let duplicateID = UUID()
        let configs = [
            VirtualDisplayConfig(
                id: duplicateID,
                name: "",
                serialNum: 0,
                physicalWidth: 0,
                physicalHeight: 0,
                modes: [],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                id: duplicateID,
                name: "Second",
                serialNum: 0,
                physicalWidth: 100,
                physicalHeight: 50,
                modes: [.init(width: 0, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: false
            )
        ]

        let data = try JSONEncoder().encode(VirtualDisplayStore.FileFormat(schemaVersion: 1, configs: configs))
        let decoded = try VirtualDisplayStore().decodeConfigs(from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].serialNum == 1)
        #expect(decoded[1].serialNum == 2)
        #expect(decoded[0].name == "Virtual Display 1")
        #expect(decoded[0].physicalWidth == 310)
        #expect(decoded[0].physicalHeight == 174)
        #expect(decoded[0].modes.first?.width == 1920)
        #expect(decoded[0].modes.first?.height == 1080)
        #expect(decoded[1].modes.first?.width == 1920)
        #expect(decoded[1].modes.first?.height == 1080)
        #expect(Set(decoded.map(\.id)).count == 2)
    }

    @MainActor @Test func virtualDisplayStoreResolvesDuplicateSerialNumbers() throws {
        let configs = [
            VirtualDisplayConfig(
                name: "Display A",
                serialNum: 1,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                name: "Display B",
                serialNum: 1,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                name: "Display C",
                serialNum: 2,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1280, height: 720, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: false
            )
        ]

        let data = try JSONEncoder().encode(VirtualDisplayStore.FileFormat(schemaVersion: 2, configs: configs))
        let decoded = try VirtualDisplayStore().decodeConfigs(from: data)
        let serials = decoded.map(\.serialNum)

        #expect(decoded.count == 3)
        #expect(Set(serials).count == 3)
        #expect(serials == [1, 2, 3])
    }

}
