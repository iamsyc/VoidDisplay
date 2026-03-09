import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Observation
import OSLog

@MainActor
@Observable
final class ShareViewModel {
    typealias LoadErrorInfo = ScreenCaptureDisplayCatalogLoadErrorInfo

    struct SharingQueries {
        var isWebServiceRunning: @MainActor () -> Bool
        var sharePageAddress: @MainActor (CGDirectDisplayID) -> String?
        var preferredWebServicePort: @MainActor () -> UInt16
    }

    struct SharingActions {
        var startWebService: @MainActor (UInt16) async -> WebServiceStartResult
        var stopWebService: @MainActor () -> Void
        var registerShareableDisplays: @MainActor ([SCDisplay], @escaping (CGDirectDisplayID) -> UInt32?) -> Void
        var beginSharing: @MainActor (SCDisplay) async throws -> Void
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
                    sharePageAddress: { displayID in sharing.sharePageAddress(for: displayID) },
                    preferredWebServicePort: { sharing.preferredWebServicePort }
                ),
                sharingActions: .init(
                    startWebService: { requestedPort in
                        await sharing.startWebService(requestedPort: requestedPort)
                    },
                    stopWebService: { sharing.stopWebService() },
                    registerShareableDisplays: { displays, resolver in
                        sharing.registerShareableDisplays(displays, virtualSerialResolver: resolver)
                    },
                    beginSharing: { display in
                        try await sharing.beginSharing(display: display)
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
    var servicePortInput = "" {
        didSet {
            let sanitized = String(servicePortInput.prefix(5))
            if servicePortInput != sanitized {
                servicePortInput = sanitized
                return
            }
            if oldValue != servicePortInput {
                portInputErrorMessage = nil
            }
        }
    }
    var portInputErrorMessage: String?
    var isStartingService = false
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    var userFacingAlert: UserFacingAlertState?

    private let topologyCoordinator: ScreenCaptureCatalogTopologyCoordinator
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let catalogLoader: ScreenCaptureDisplayCatalogLoader

    init(
        catalogState: ScreenCaptureDisplayCatalogState? = nil,
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: (@MainActor () async throws -> [SCDisplay])? = nil,
        activeDisplayIDsProvider: @escaping @MainActor () -> Set<CGDirectDisplayID> = {
            Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        },
        dependencies: Dependencies
    ) {
        let catalog = catalogState ?? ScreenCaptureDisplayCatalogState()
        self.catalog = catalog
        self.topologyCoordinator = ScreenCaptureCatalogTopologyCoordinator(
            state: catalog,
            activeDisplayIDsProvider: activeDisplayIDsProvider
        )
        self.dependencies = dependencies
        self.catalogLoader = ScreenCaptureDisplayCatalogLoader(
            state: catalog,
            permissionProvider: permissionProvider,
            loadShareableDisplays: loadShareableDisplays,
            logOperation: "Load shareable displays (sharing)",
            logger: AppLog.capture
        )
        self.servicePortInput = String(dependencies.sharingQueries.preferredWebServicePort())
    }

    func syncForCurrentState(
        clearDisplaysWhenPermissionDenied: Bool = true,
        clearDisplaysWhenServiceStopped: Bool = true
    ) {
        guard catalog.hasScreenCapturePermission == true else {
            if clearDisplaysWhenPermissionDenied {
                catalogLoader.clearDisplaysAndCancel()
            } else {
                catalogLoader.cancelInFlightDisplayLoad()
            }
            return
        }
        guard dependencies.sharingQueries.isWebServiceRunning() else {
            if clearDisplaysWhenServiceStopped {
                catalogLoader.clearDisplaysAndCancel()
            } else {
                catalogLoader.cancelInFlightDisplayLoad()
            }
            return
        }
        refreshDisplaysForCurrentTopologyIfNeeded()
    }

    func startService() {
        Task { @MainActor in
            isStartingService = true
            defer { isStartingService = false }
            portInputErrorMessage = nil

            let requestedPort: UInt16
            switch SharePortValidationError.parse(servicePortInput) {
            case .success(let parsed):
                requestedPort = parsed
            case .failure(let validationError):
                presentPortInputError(validationError.userMessage)
                return
            }

            let startResult = await dependencies.sharingActions.startWebService(requestedPort)
            if case .failed(let failure) = startResult {
                AppLog.sharing.error(
                    "Start service failed (requestedPort: \(requestedPort, privacy: .public), reason: \(String(describing: failure), privacy: .public))."
                )
                presentPortInputError(failure.userMessage)
                return
            }
            servicePortInput = String(requestedPort)
            portInputErrorMessage = nil
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
        syncForCurrentState(clearDisplaysWhenServiceStopped: false)
    }

    func loadDisplaysIfNeeded() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        catalogLoader.loadDisplaysIfNeeded { [weak self] displays in
            self?.handleDisplaysLoaded(displays)
        }
    }

    func loadDisplays() {
        catalogLoader.loadDisplays { [weak self] displays in
            self?.handleDisplaysLoaded(displays)
        }
    }

    func refreshDisplays() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        catalogLoader.loadDisplays(preserveExistingDisplays: true) { [weak self] displays in
            self?.handleDisplaysLoaded(displays)
        }
    }

    func refreshDisplaysBackgroundSafe() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        guard !catalog.isLoadingDisplays else { return }
        guard topologyCoordinator.needsRefresh() else { return }
        if catalog.displays == nil {
            loadDisplaysIfNeeded()
            return
        }
        catalogLoader.loadDisplays(preserveExistingDisplays: true) { [weak self] displays in
            self?.handleDisplaysLoaded(displays)
        }
    }

    func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        topologyCoordinator.visibleDisplays(from: displays)
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
                let requestedPort: UInt16
                switch SharePortValidationError.parse(servicePortInput) {
                case .success(let parsed):
                    requestedPort = parsed
                case .failure(let validationError):
                    presentPortInputError(validationError.userMessage)
                    return
                }
                let result = await dependencies.sharingActions.startWebService(requestedPort)
                if case .failed(let failure) = result {
                    presentPortInputError(failure.userMessage)
                    return
                }
                ready = true
            }
            guard ready else {
                presentError(
                    title: String(localized: "Share Failed"),
                    message: String(localized: "Web service is not running.")
                )
                return
            }

            do {
                try await dependencies.sharingActions.beginSharing(display)
            } catch {
                dependencies.sharingActions.stopSharing(display.displayID)
                AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
                presentError(
                    title: String(localized: "Share Failed"),
                    message: AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to start sharing."))
                )
            }
        }
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        dependencies.sharingActions.stopSharing(displayID)
    }

    func sharePageAddress(for displayID: CGDirectDisplayID) -> String? {
        dependencies.sharingQueries.sharePageAddress(displayID)
    }

    func dismissAlert() {
        userFacingAlert = nil
    }

    func cancelInFlightDisplayLoad() {
        catalogLoader.cancelInFlightDisplayLoad()
    }

    private func refreshDisplaysForCurrentTopologyIfNeeded() {
        guard topologyCoordinator.needsRefresh() else { return }
        if catalog.displays == nil {
            loadDisplaysIfNeeded()
            return
        }
        catalogLoader.loadDisplays(preserveExistingDisplays: true) { [weak self] displays in
            self?.handleDisplaysLoaded(displays)
        }
    }

    private func handleDisplaysLoaded(_ displays: [SCDisplay]) {
        topologyCoordinator.commitLoadedTopologySignature()
        registerShareableDisplays(displays)
    }

    private func registerShareableDisplays(_ displays: [SCDisplay]) {
        dependencies.sharingActions.registerShareableDisplays(displays) { [weak self] displayID in
            self?.dependencies.virtualDisplayQueries.virtualSerialForManagedDisplay(displayID)
        }
    }

    private func presentError(title: String, message: String) {
        userFacingAlert = UserFacingAlertState(title: title, message: message)
    }

    private func presentPortInputError(_ message: String) {
        portInputErrorMessage = message
    }
}
