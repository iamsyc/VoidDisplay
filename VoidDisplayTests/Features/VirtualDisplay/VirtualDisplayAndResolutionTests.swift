//
//  VoidDisplayTests.swift
//  VoidDisplayTests
//
//

import Testing
import Foundation
@testable import VoidDisplay

@MainActor
struct VirtualDisplayAndResolutionTests {

    @Test func resolutionsParsing() {
        let res = DisplayResolutionPreset.w1920h1080.resolutions
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
            displayName: "No HiDPI",
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
            displayName: "HiDPI",
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
            displayName: "Fallback",
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
          "displayName": "Strict Config",
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
            displayName: "Round Trip",
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
            displayName: "Stored Config",
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
            displayName: "Legacy Array",
            serialNum: 42,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)],
            desiredEnabled: true
        )

        let data = try JSONEncoder().encode([config])
        do {
            _ = try VirtualDisplayStore().decodeConfigs(from: data)
            Issue.record("Expected legacy array format decode to fail")
        } catch let error as VirtualDisplayConfigStoreError {
            guard case .decodingFailed = error else {
                Issue.record("Expected decodingFailed, got \(error)")
                return
            }
        }
    }

    @MainActor @Test func virtualDisplayStoreSanitizesInvalidAndDuplicateConfigs() throws {
        let duplicateID = UUID()
        let configs = [
            VirtualDisplayConfig(
                id: duplicateID,
                displayName: "",
                serialNum: 0,
                physicalWidth: 0,
                physicalHeight: 0,
                modes: [],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                id: duplicateID,
                displayName: "Second",
                serialNum: 0,
                physicalWidth: 100,
                physicalHeight: 50,
                modes: [.init(width: 0, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: false
            )
        ]

        let data = try JSONEncoder().encode(VirtualDisplayStore.FileFormat(schemaVersion: 3, configs: configs))
        let decoded = try VirtualDisplayStore().decodeConfigs(from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].serialNum == 1)
        #expect(decoded[1].serialNum == 2)
        #expect(decoded[0].displayName == "Virtual Display 1")
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
                displayName: "Display A",
                serialNum: 1,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                displayName: "Display B",
                serialNum: 1,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                displayName: "Display C",
                serialNum: 2,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1280, height: 720, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: false
            )
        ]

        let data = try JSONEncoder().encode(VirtualDisplayStore.FileFormat(schemaVersion: 3, configs: configs))
        let decoded = try VirtualDisplayStore().decodeConfigs(from: data)
        let serials = decoded.map(\.serialNum)

        #expect(decoded.count == 3)
        #expect(Set(serials).count == 3)
        #expect(serials == [1, 2, 3])
    }

    @MainActor @Test func virtualDisplayStoreSaveDoesNotRewriteDisplayNamesHeuristically() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = VirtualDisplayStore(
            appSupportDirectoryOverride: tempRoot,
            bundleIdentifierOverride: "com.example.voiddisplay.testsandbox",
            environment: [:]
        )

        let runtimePolluted = VirtualDisplayConfig(
            id: UUID(),
            displayName: "Managed 1",
            serialNum: 1,
            physicalWidth: 286,
            physicalHeight: 179,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        try store.save([runtimePolluted])

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == "Managed 1")
        #expect(loaded.first?.modes.first?.width == 1920)
        #expect(loaded.first?.modes.first?.height == 1080)
    }

    @MainActor @Test func virtualDisplayStoreDiagnosticsReportsPrimaryPathAndIsolationState() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = VirtualDisplayStore(
            appSupportDirectoryOverride: tempRoot,
            bundleIdentifierOverride: "com.example.voiddisplay",
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        )

        let diagnostics = try store.diagnostics()

        #expect(diagnostics.primaryStoreURL.path.contains("com.example.voiddisplay.tests"))
        #expect(diagnostics.isTestIsolatedPath)
    }

    @MainActor @Test func virtualDisplayStoreLoadRejectsSchemaVersion2WithStructuredError() throws {
        let json = """
        {
          "schemaVersion": 2,
          "configs": []
        }
        """
        let data = try #require(json.data(using: .utf8))

        do {
            _ = try VirtualDisplayStore().decodeConfigs(from: data)
            Issue.record("Expected unsupported schema version error")
        } catch let error as VirtualDisplayConfigStoreError {
            switch error {
            case .unsupportedSchemaVersion(let expected, let actual):
                #expect(expected == 3)
                #expect(actual == 2)
            default:
                Issue.record("Expected unsupportedSchemaVersion error")
            }
        } catch {
            Issue.record("Unexpected error type: \(String(describing: error))")
        }
    }

    @MainActor @Test func virtualDisplayStoreRejectsLegacyNameKeySchema() throws {
        let id = UUID().uuidString
        let json = """
        {
          "schemaVersion": 3,
          "configs": [
            {
              "id": "\(id)",
              "name": "Legacy Field",
              "serialNum": 1,
              "physicalWidth": 300,
              "physicalHeight": 200,
              "modes": [
                { "width": 1920, "height": 1080, "refreshRate": 60, "enableHiDPI": false }
              ],
              "desiredEnabled": true
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        do {
            _ = try VirtualDisplayStore().decodeConfigs(from: data)
            Issue.record("Expected decodingFailed store error")
        } catch let error as VirtualDisplayConfigStoreError {
            switch error {
            case .decodingFailed:
                break
            default:
                Issue.record("Expected decodingFailed error")
            }
        } catch {
            Issue.record("Unexpected error type: \(String(describing: error))")
        }
    }

    @MainActor @Test func virtualDisplayStoreUsesIsolatedBundleSuffixWhenRunningUnderXCTest() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let baseBundleID = "com.example.voiddisplay"
        let store = VirtualDisplayStore(
            appSupportDirectoryOverride: tempRoot,
            bundleIdentifierOverride: baseBundleID,
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        )

        let config = VirtualDisplayConfig(
            displayName: "Test",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        try store.save([config])

        let isolatedURL = tempRoot
            .appendingPathComponent("\(baseBundleID).tests", isDirectory: true)
            .appendingPathComponent("virtual-displays.json", isDirectory: false)
        let normalURL = tempRoot
            .appendingPathComponent(baseBundleID, isDirectory: true)
            .appendingPathComponent("virtual-displays.json", isDirectory: false)

        #expect(FileManager.default.fileExists(atPath: isolatedURL.path))
        #expect(FileManager.default.fileExists(atPath: normalURL.path) == false)
    }

}
