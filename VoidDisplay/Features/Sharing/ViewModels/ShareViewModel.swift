import Foundation
import ScreenCaptureKit
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class ShareViewModel {
    typealias LoadErrorInfo = ScreenCaptureDisplayCatalogLoadErrorInfo

    struct SharingQueries {
        var isWebServiceRunning: @MainActor () -> Bool
        var sharePageAddress: @MainActor (CGDirectDisplayID) -> String?
    }

    struct SharingActions {
        var startWebService: @MainActor () async -> Bool
        var stopWebService: @MainActor () -> Void
        var registerShareableDisplays: @MainActor ([SCDisplay], @escaping (CGDirectDisplayID) -> UInt32?) -> Void
        var beginSharing: @MainActor (CGDirectDisplayID, SCStream, Capture, StreamDelegate) -> Void
        var stopSharing: @MainActor (CGDirectDisplayID) -> Void
    }

    struct VirtualDisplayQueries {
        var virtualSerialForManagedDisplay: @MainActor (CGDirectDisplayID) -> UInt32?
    }

    struct Dependencies {
        var sharingQueries: SharingQueries
        var sharingActions: SharingActions
        var virtualDisplayQueries: VirtualDisplayQueries

        static func live(
            sharing: SharingController,
            virtualDisplay: VirtualDisplayController
        ) -> Self {
            .init(
                sharingQueries: .init(
                    isWebServiceRunning: { sharing.isWebServiceRunning },
                    sharePageAddress: { displayID in sharing.sharePageAddress(for: displayID) }
                ),
                sharingActions: .init(
                    startWebService: { await sharing.startWebService() },
                    stopWebService: { sharing.stopWebService() },
                    registerShareableDisplays: { displays, resolver in
                        sharing.registerShareableDisplays(displays, virtualSerialResolver: resolver)
                    },
                    beginSharing: { displayID, stream, output, delegate in
                        sharing.beginSharing(displayID: displayID, stream: stream, output: output, delegate: delegate)
                    },
                    stopSharing: { displayID in sharing.stopSharing(displayID: displayID) }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { displayID in
                        virtualDisplay.virtualSerialForManagedDisplay(displayID)
                    }
                )
            )
        }

    }

    let catalog: ScreenCaptureDisplayCatalogState
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    var showOpenPageError = false
    var openPageErrorMessage = ""

    private let makeScreenCaptureSession: @MainActor (SCDisplay) async -> ScreenCaptureSession
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let catalogLoader: ScreenCaptureDisplayCatalogLoader

    init(
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: (@MainActor () async throws -> [SCDisplay])? = nil,
        makeScreenCaptureSession: (@MainActor (SCDisplay) async -> ScreenCaptureSession)? = nil,
        dependencies: Dependencies
    ) {
        let catalog = ScreenCaptureDisplayCatalogState()
        self.catalog = catalog
        self.makeScreenCaptureSession = makeScreenCaptureSession ?? { display in
            await createScreenCapture(display: display)
        }
        self.dependencies = dependencies
        self.catalogLoader = ScreenCaptureDisplayCatalogLoader(
            state: catalog,
            permissionProvider: permissionProvider,
            loadShareableDisplays: loadShareableDisplays,
            logOperation: "Load shareable displays (sharing)",
            logger: AppLog.capture
        )
    }

    func syncForCurrentState() {
        guard catalog.hasScreenCapturePermission == true else {
            catalogLoader.clearDisplaysAndCancel()
            return
        }
        guard dependencies.sharingQueries.isWebServiceRunning() else {
            catalogLoader.clearDisplaysAndCancel()
            return
        }
        loadDisplaysIfNeeded()
    }

    func startService() {
        Task { @MainActor in
            guard await dependencies.sharingActions.startWebService() else {
                AppLog.sharing.error("Start service failed.")
                presentError(String(localized: "Failed to start web service."))
                return
            }
            syncForCurrentState()
        }
    }

    func stopService() {
        catalogLoader.cancelInFlightDisplayLoad()
        dependencies.sharingActions.stopWebService()
        syncForCurrentState()
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        catalogLoader.openScreenCapturePrivacySettings(openURL: openURL)
    }

    func requestScreenCapturePermission() {
        let granted = catalogLoader.requestPermission()

        AppLog.capture.notice(
            "Screen capture permission request (sharing): requestResult=\((self.catalog.lastRequestPermission ?? false), privacy: .public), preflightResult=\(granted, privacy: .public)"
        )

        if !granted {
            catalogLoader.clearDisplaysAndCancel()
            catalog.loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
            AppLog.capture.notice("Screen capture permission request denied (sharing).")
            return
        }
        syncForCurrentState()
    }

    func refreshPermissionAndMaybeLoad() {
        let granted = catalogLoader.refreshPermission()
        if !granted {
            catalogLoader.clearDisplaysAndCancel()
            return
        }
        syncForCurrentState()
    }

    func loadDisplaysIfNeeded() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        catalogLoader.loadDisplaysIfNeeded { [weak self] displays in
            self?.registerShareableDisplays(displays)
        }
    }

    func loadDisplays() {
        catalogLoader.loadDisplays { [weak self] displays in
            self?.registerShareableDisplays(displays)
        }
    }

    func refreshDisplays() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        loadDisplays()
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

    func startSharing(display: SCDisplay) async {
        _ = await withDisplayStartLock(displayID: display.displayID) {
            let ready: Bool
            if dependencies.sharingQueries.isWebServiceRunning() {
                ready = true
            } else {
                ready = await dependencies.sharingActions.startWebService()
            }
            guard ready else {
                presentError(String(localized: "Web service is not running."))
                return
            }

            let captureSession = await makeScreenCaptureSession(display)
            let stream = Capture()

            do {
                try captureSession.stream.addStreamOutput(
                    stream,
                    type: .screen,
                    sampleHandlerQueue: stream.sampleHandlerQueue
                )
                try await captureSession.stream.startCapture()
                dependencies.sharingActions.beginSharing(
                    display.displayID,
                    captureSession.stream,
                    stream,
                    captureSession.delegate
                )
            } catch {
                dependencies.sharingActions.stopSharing(display.displayID)
                AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
                presentError(AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to start sharing.")))
            }
        }
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        dependencies.sharingActions.stopSharing(displayID)
    }

    func sharePageAddress(for displayID: CGDirectDisplayID) -> String? {
        dependencies.sharingQueries.sharePageAddress(displayID)
    }

    func clearError() {
        showOpenPageError = false
    }

    func cancelInFlightDisplayLoad() {
        catalogLoader.cancelInFlightDisplayLoad()
    }

    private func registerShareableDisplays(_ displays: [SCDisplay]) {
        dependencies.sharingActions.registerShareableDisplays(displays) { [weak self] displayID in
            self?.dependencies.virtualDisplayQueries.virtualSerialForManagedDisplay(displayID)
        }
    }

    private func presentError(_ message: String) {
        openPageErrorMessage = message
        showOpenPageError = true
    }
}
