import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation

@MainActor
@Observable
package final class CaptureChooseViewModel {
    package struct Dependencies {
        package var captureActions: CaptureMonitoringActions
        package var virtualDisplayStatusProvider: CaptureVirtualDisplayStatusProvider

        package init(
            captureActions: CaptureMonitoringActions,
            virtualDisplayStatusProvider: CaptureVirtualDisplayStatusProvider
        ) {
            self.captureActions = captureActions
            self.virtualDisplayStatusProvider = virtualDisplayStatusProvider
        }
    }

    package let catalog: ScreenCaptureDisplayCatalogState
    package var userFacingAlert: UserFacingAlertState?

    @ObservationIgnored private let activeDisplayIDsProvider: @MainActor () -> Set<CGDirectDisplayID>
    @ObservationIgnored private let dependencies: Dependencies

    package init(
        catalogState: ScreenCaptureDisplayCatalogState? = nil,
        activeDisplayIDsProvider: @escaping @MainActor () -> Set<CGDirectDisplayID> = {
            Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        },
        dependencies: Dependencies
    ) {
        self.catalog = catalogState ?? ScreenCaptureDisplayCatalogState()
        self.activeDisplayIDsProvider = activeDisplayIDsProvider
        self.dependencies = dependencies
    }

    package func isVirtualDisplay(_ display: SCDisplay) -> Bool {
        dependencies.virtualDisplayStatusProvider.isManagedVirtualDisplay(display.displayID)
    }

    package func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? String(localized: "Monitor")
    }

    package func resolutionText(for display: SCDisplay) -> String {
        // SCDisplay already reports pixel dimensions, so this matches the UI's "pixel resolution"
        // presentation used elsewhere even though other screens may derive it from NSScreen backing.
        "\(display.width) × \(display.height)"
    }

    package func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        dependencies.captureActions.isStartingDisplayID(displayID)
    }

    package func startMonitoring(
        display: SCDisplay,
        openWindow: @escaping (UUID) -> Void
    ) async {
        if let existingSession = dependencies.captureActions.monitoringSessionForDisplayID(display.displayID) {
            openWindow(existingSession.id)
            return
        }
        guard !isStarting(displayID: display.displayID) else { return }

        do {
            let metadata = CaptureMonitoringDisplayMetadata(
                displayName: displayName(for: display),
                resolutionText: resolutionText(for: display),
                isVirtualDisplay: isVirtualDisplay(display)
            )
            let outcome = try await dependencies.captureActions.startMonitoring(display, metadata)
            switch outcome {
            case .started(let sessionID):
                openWindow(sessionID)
            case .invalidated:
                break
            }
        } catch is CancellationError {
        } catch {
            AppErrorMapper.logFailure("Start monitoring", error: error, logger: AppLog.capture)
            userFacingAlert = UserFacingAlertState(
                title: String(localized: "Start Monitoring Failed"),
                message: AppErrorMapper.userMessage(
                    for: error,
                    fallback: String(localized: "Failed to start monitoring.")
                )
            )
        }
    }

    package func dismissAlert() {
        userFacingAlert = nil
    }
}
