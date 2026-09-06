@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
//
//  VoidDisplayTests.swift
//  VoidDisplayTests
//
//

import Testing
import Foundation

@MainActor
struct VirtualDisplayAndResolutionTests {

    @Test func storeRejectsInvalidModeBoundsOnSaveAndLoad() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".ai-tmp/mode-store-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(storeURL: root.appendingPathComponent("displays.json"))
        for mode in [
            VirtualDisplayConfig.ModeConfig(width: 8193, height: 1, refreshRate: 60, enableHiDPI: false),
            .init(width: 1, height: 4097, refreshRate: 60, enableHiDPI: true),
            .init(width: Int.max, height: 1, refreshRate: 60, enableHiDPI: true),
            .init(width: 0, height: 1080, refreshRate: 60, enableHiDPI: false),
            .init(width: 1920, height: 1080, refreshRate: 0, enableHiDPI: false)
        ] {
            let config = VirtualDisplayConfig(
                displayName: "Invalid", serialNum: 1, physicalWidth: 300, physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false), mode]
            )
            #expect(throws: VirtualDisplayConfigStoreError.self) { try store.save([config]) }
            let data = try JSONEncoder().encode(VirtualDisplayStore.FileFormat(schemaVersion: 3, configs: [config]))
            #expect(throws: VirtualDisplayConfigStoreError.self) { try store.decodeConfigs(from: data) }
        }
    }

    @Test func resolutionsParsing() {
        let res = DisplayResolutionPreset.w1920h1080.logicalSize
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

    @MainActor @Test func virtualDisplayStoreRejectsInvalidConfigs() throws {
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
        do {
            _ = try makeStore().decodeConfigs(from: data)
            Issue.record("Expected invalid configuration error")
        } catch let error as VirtualDisplayConfigStoreError {
            guard case .invalidConfiguration(let index, _) = error else {
                Issue.record("Expected invalidConfiguration error")
                return
            }
            #expect(index == 0)
        } catch {
            Issue.record("Unexpected error type: \(String(describing: error))")
        }
    }

    @MainActor @Test func virtualDisplayStoreRejectsDuplicateSerialNumbers() throws {
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
        do {
            _ = try makeStore().decodeConfigs(from: data)
            Issue.record("Expected duplicate serial number rejection")
        } catch let error as VirtualDisplayConfigStoreError {
            guard case .invalidConfiguration(let index, _) = error else {
                Issue.record("Expected invalidConfiguration error")
                return
            }
            #expect(index == 1)
        } catch {
            Issue.record("Unexpected error type: \(String(describing: error))")
        }
    }

    @MainActor @Test func virtualDisplayStoreSaveDoesNotRewriteDisplayNamesHeuristically() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storeURL = tempRoot.appendingPathComponent("virtual-displays.json", isDirectory: false)
        let store = makeStore(storeURL: storeURL)

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

        let storeURL = tempRoot.appendingPathComponent("virtual-displays.json", isDirectory: false)
        let store = makeStore(storeURL: storeURL, mode: .testIsolatedWritable)

        let diagnostics = store.diagnostics()

        #expect(diagnostics.primaryStoreURL == storeURL)
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
            _ = try makeStore().decodeConfigs(from: data)
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

    @MainActor @Test func virtualDisplayStoreWritesOnlyToInjectedStoreURL() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storeURL = tempRoot
            .appendingPathComponent("sandbox", isDirectory: true)
            .appendingPathComponent("virtual-displays.json", isDirectory: false)
        let store = makeStore(storeURL: storeURL, mode: .testIsolatedWritable)

        let config = VirtualDisplayConfig(
            displayName: "Test",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        try store.save([config])

        let siblingURL = tempRoot
            .appendingPathComponent("virtual-displays.json", isDirectory: false)

        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path) == false)
    }

    private func makeStore(
        storeURL: URL? = nil,
        mode: PersistenceMode = .testIsolatedWritable
    ) -> VirtualDisplayStore {
        let url = storeURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("virtual-displays.json", isDirectory: false)
        return VirtualDisplayStore(storeURL: url, mode: mode)
    }
}
