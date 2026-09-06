import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
package enum UITestScreenCaptureCatalogFixture {
    private final class MockSCDisplayBox: NSObject {
        @objc let displayID: CGDirectDisplayID
        @objc let width: Int
        @objc let height: Int
        @objc let frame: CGRect

        init(displayID: CGDirectDisplayID, width: Int, height: Int) {
            self.displayID = displayID
            self.width = width
            self.height = height
            self.frame = CGRect(x: 0, y: 0, width: width, height: height)
            super.init()
        }
    }

    private static let fallbackDisplayID = CGDirectDisplayID(9_001)

    package static func makeShareableDisplays(for scenario: UITestScenario) -> [SCDisplay] {
        var displays = NSScreen.screens.compactMap(makeDisplay(for:))
        if displays.isEmpty {
            displays.append(makeFallbackDisplay())
        }
        let managedVirtualDisplayIDs = UITestRuntime.catalogManagedVirtualDisplayIDs(for: scenario)
        let managedDisplayIDs = Set(UITestRuntime.managedVirtualDisplayIDs)
        displays.removeAll { managedDisplayIDs.contains($0.displayID) }
        displays.append(contentsOf: managedVirtualDisplayIDs.map { displayID in
            makeDisplay(
                displayID: displayID,
                width: 1920,
                height: 1080
            )
        })
        return displays
    }

    package static func activeDisplayIDs(for scenario: UITestScenario) -> Set<CGDirectDisplayID> {
        var ids = Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        if ids.isEmpty {
            ids.insert(fallbackDisplayID)
        }
        ids.subtract(UITestRuntime.managedVirtualDisplayIDs)
        ids.formUnion(UITestRuntime.catalogManagedVirtualDisplayIDs(for: scenario))
        return ids
    }

    package nonisolated static func makeLoader(
        for scenario: UITestScenario,
        clock: some Clock<Duration> = ContinuousClock()
    ) -> ScreenCaptureCatalogService.LoadShareableDisplays {
        return { @MainActor in
            if scenario == .displayCatalogLoading || scenario == .displayCatalogLoadingWithMissingManagedDisplay {
                try await clock.sleep(for: .seconds(3))
            }
            return makeShareableDisplays(for: scenario)
        }
    }

    private static func makeDisplay(for screen: NSScreen) -> SCDisplay? {
        guard let displayID = screen.cgDirectDisplayID else { return nil }
        let scale = max(screen.backingScaleFactor, 1)
        let width = max(Int(screen.frame.width * scale), 1)
        let height = max(Int(screen.frame.height * scale), 1)
        return makeDisplay(displayID: displayID, width: width, height: height)
    }

    private static func makeFallbackDisplay() -> SCDisplay {
        makeDisplay(displayID: fallbackDisplayID, width: 1728, height: 1117)
    }

    private static func makeDisplay(
        displayID: CGDirectDisplayID,
        width: Int,
        height: Int
    ) -> SCDisplay {
        let box = MockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}
package enum ScreenCaptureShareableDisplayLoaderFactory {
    package static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScreenCaptureCatalogService.LoadShareableDisplays {
        if environment[UITestRuntime.modeEnvironmentKey] == "1" {
            let scenario = UITestScenario(rawValue: environment[UITestRuntime.scenarioEnvironmentKey] ?? "") ?? .baseline
            return UITestScreenCaptureCatalogFixture.makeLoader(for: scenario)
        }

        if environment[PersistenceContext.xCTestConfigurationEnvironmentKey] != nil {
            return { [] }
        }

        return {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return content.displays
        }
    }
}
package enum ScreenCaptureActiveDisplayIDsProviderFactory {
    package static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScreenCaptureCatalogService.ActiveDisplayIDsProvider {
        if environment[UITestRuntime.modeEnvironmentKey] == "1" {
            let scenario = UITestScenario(rawValue: environment[UITestRuntime.scenarioEnvironmentKey] ?? "") ?? .baseline
            return {
                UITestScreenCaptureCatalogFixture.activeDisplayIDs(for: scenario)
            }
        }

        return {
            Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        }
    }
}
