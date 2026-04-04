import Foundation
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class CaptureChooseViewModel {
    struct CaptureActions {
        var monitoringSessionForDisplayID: @MainActor (CGDirectDisplayID) -> ScreenMonitoringSession?
        var isStartingDisplayID: @MainActor (CGDirectDisplayID) -> Bool
        var startMonitoring: @MainActor (
            SCDisplay,
            CaptureMonitoringDisplayMetadata
        ) async throws -> DisplayStartOutcome<UUID>
    }

    struct VirtualDisplayQueries {
        var isManagedVirtualDisplay: @MainActor (CGDirectDisplayID) -> Bool
    }

    struct Dependencies {
        var captureActions: CaptureActions
        var virtualDisplayQueries: VirtualDisplayQueries

        static func live(
            capture: CaptureController,
            virtualDisplay: VirtualDisplayController
        ) -> Self {
            .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { displayID in
                        capture.screenCaptureSessions.first(where: { $0.displayID == displayID })
                    },
                    isStartingDisplayID: { displayID in
                        capture.isStarting(displayID: displayID)
                    },
                    startMonitoring: { display, metadata in
                        try await capture.startMonitoring(display: display, metadata: metadata)
                    }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { displayID in
                        virtualDisplay.isManagedVirtualDisplay(displayID: displayID)
                    }
                )
            )
        }

    }

    let catalog: ScreenCaptureDisplayCatalogState
    var userFacingAlert: UserFacingAlertState?

    @ObservationIgnored private let activeDisplayIDsProvider: @MainActor () -> Set<CGDirectDisplayID>
    @ObservationIgnored private let dependencies: Dependencies

    init(
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

    func isVirtualDisplay(_ display: SCDisplay) -> Bool {
        dependencies.virtualDisplayQueries.isManagedVirtualDisplay(display.displayID)
    }

    func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? String(localized: "Monitor")
    }

    func resolutionText(for display: SCDisplay) -> String {
        // SCDisplay already reports pixel dimensions, so this matches the UI's "pixel resolution"
        // presentation used elsewhere even though other screens may derive it from NSScreen backing.
        "\(display.width) × \(display.height)"
    }

    func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        dependencies.captureActions.isStartingDisplayID(displayID)
    }

    func startMonitoring(
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

    func dismissAlert() {
        userFacingAlert = nil
    }
}
