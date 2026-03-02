import Foundation
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class CaptureChooseViewModel {
    typealias LoadErrorInfo = ScreenCaptureDisplayCatalogLoadErrorInfo

    struct CaptureActions {
        var monitoringSessionForDisplayID: @MainActor (CGDirectDisplayID) -> ScreenMonitoringSession?
        var addMonitoringSession: @MainActor (ScreenMonitoringSession) -> Void
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
                    addMonitoringSession: { session in
                        capture.addMonitoringSession(session)
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
    var startingDisplayIDs: Set<CGDirectDisplayID> = []

    private let makePreviewSubscription: @MainActor (SCDisplay) async throws -> DisplayPreviewSubscription
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let catalogLoader: ScreenCaptureDisplayCatalogLoader

    init(
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: (@MainActor () async throws -> [SCDisplay])? = nil,
        makePreviewSubscription: (@MainActor (SCDisplay) async throws -> DisplayPreviewSubscription)? = nil,
        dependencies: Dependencies
    ) {
        let catalog = ScreenCaptureDisplayCatalogState()
        self.catalog = catalog
        self.makePreviewSubscription = makePreviewSubscription ?? { display in
            try await DisplayCaptureRegistry.shared.acquirePreview(display: SendableDisplay(display))
        }
        self.dependencies = dependencies
        self.catalogLoader = ScreenCaptureDisplayCatalogLoader(
            state: catalog,
            permissionProvider: permissionProvider,
            loadShareableDisplays: loadShareableDisplays,
            logOperation: "Load shareable displays",
            logger: AppLog.capture
        )
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

    @discardableResult
    func withDisplayStartLock(
        displayID: CGDirectDisplayID,
        operation: () async -> Void
    ) async -> Bool {
        guard !startingDisplayIDs.contains(displayID) else { return false }
        startingDisplayIDs.insert(displayID)
        defer { startingDisplayIDs.remove(displayID) }
        await operation()
        return true
    }

    func startMonitoring(
        display: SCDisplay,
        openWindow: @escaping (UUID) -> Void
    ) async {
        _ = await withDisplayStartLock(displayID: display.displayID) {
            if let existingSession = dependencies.captureActions.monitoringSessionForDisplayID(display.displayID) {
                openWindow(existingSession.id)
                return
            }

            do {
                let previewSubscription = try await makePreviewSubscription(display)
                let session = ScreenMonitoringSession(
                    id: UUID(),
                    displayID: display.displayID,
                    displayName: displayName(for: display),
                    resolutionText: resolutionText(for: display),
                    isVirtualDisplay: isVirtualDisplay(display),
                    previewSubscription: previewSubscription,
                    state: .starting
                )
                dependencies.captureActions.addMonitoringSession(session)
                openWindow(session.id)
            } catch {
                AppErrorMapper.logFailure("Start monitoring", error: error, logger: AppLog.capture)
            }
        }
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        catalogLoader.openScreenCapturePrivacySettings(openURL: openURL)
    }

    func requestScreenCapturePermission() {
        let granted = catalogLoader.requestPermission()
        if !granted {
            catalogLoader.clearDisplaysAndCancel()
            AppLog.capture.notice("Screen capture permission request denied.")
            return
        }
        loadDisplays()
    }

    func refreshPermissionAndMaybeLoad() {
        let granted = catalogLoader.refreshPermission()
        if !granted {
            catalogLoader.cancelInFlightDisplayLoad()
            AppLog.capture.notice("Screen capture permission preflight denied.")
        }
        if granted {
            loadDisplays()
        }
    }

    func loadDisplays() {
        catalogLoader.loadDisplays()
    }

    func cancelInFlightDisplayLoad() {
        catalogLoader.cancelInFlightDisplayLoad()
    }
}
