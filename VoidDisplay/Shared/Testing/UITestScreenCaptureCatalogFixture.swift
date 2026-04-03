import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
enum UITestScreenCaptureCatalogFixture {
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

    static func makeShareableDisplays() -> [SCDisplay] {
        let displays = NSScreen.screens.compactMap(makeDisplay(for:))
        if displays.isEmpty {
            return [makeFallbackDisplay()]
        }
        return displays
    }

    static func activeDisplayIDs() -> Set<CGDirectDisplayID> {
        let ids = Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        if ids.isEmpty {
            return [fallbackDisplayID]
        }
        return ids
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

enum ScreenCaptureShareableDisplayLoaderFactory {
    static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScreenCaptureCatalogService.LoadShareableDisplays {
        if environment[UITestRuntime.modeEnvironmentKey] == "1" {
            return {
                UITestScreenCaptureCatalogFixture.makeShareableDisplays()
            }
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

enum ScreenCaptureActiveDisplayIDsProviderFactory {
    static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScreenCaptureCatalogService.ActiveDisplayIDsProvider {
        if environment[UITestRuntime.modeEnvironmentKey] == "1" {
            return {
                UITestScreenCaptureCatalogFixture.activeDisplayIDs()
            }
        }

        return {
            Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        }
    }
}
