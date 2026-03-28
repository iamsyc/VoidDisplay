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
    typealias RefreshIntent = ScreenCaptureCatalogRefreshIntent

    struct SharingQueries {
        var isWebServiceRunning: @MainActor () -> Bool
        var isStartingDisplayID: @MainActor (CGDirectDisplayID) -> Bool
        var sharePageAddress: @MainActor (CGDirectDisplayID) -> String?
        var preferredWebServicePort: @MainActor () -> UInt16
    }

    struct SharingActions {
        var startWebService: @MainActor (UInt16) async -> WebServiceStartResult
        var stopWebService: @MainActor () -> Void
        var registerShareableDisplays: @MainActor ([SCDisplay], @escaping (CGDirectDisplayID) -> UInt32?) -> Void
        var beginSharing: @MainActor (SCDisplay) async throws -> DisplayStartOutcome<Void>
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
                    isStartingDisplayID: { displayID in sharing.isStarting(displayID: displayID) },
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
    var userFacingAlert: UserFacingAlertState?

    private let catalogService: ScreenCaptureCatalogService
    @ObservationIgnored private let refreshOwner = ScreenCaptureCatalogService.RefreshOwner()
    @ObservationIgnored private let dependencies: Dependencies

    init(
        catalogService: ScreenCaptureCatalogService? = nil,
        catalogState: ScreenCaptureDisplayCatalogState? = nil,
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: (@MainActor () async throws -> [SCDisplay])? = nil,
        activeDisplayIDsProvider: @escaping @MainActor () -> Set<CGDirectDisplayID> = {
            Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
        },
        dependencies: Dependencies
    ) {
        let resolvedCatalogService = catalogService ?? ScreenCaptureCatalogService(
            store: catalogState,
            permissionProvider: permissionProvider,
            loadShareableDisplays: loadShareableDisplays,
            activeDisplayIDsProvider: activeDisplayIDsProvider,
            logOperation: "Load shareable displays (sharing)",
            logger: AppLog.capture
        )
        self.catalogService = resolvedCatalogService
        self.catalog = resolvedCatalogService.store
        self.dependencies = dependencies
        self.servicePortInput = String(dependencies.sharingQueries.preferredWebServicePort())
        if dependencies.sharingQueries.isWebServiceRunning() {
            replayShareableDisplaysIfAvailable()
        }
    }

    func syncForCurrentState(
        clearDisplaysWhenPermissionDenied: Bool = true,
        clearDisplaysWhenServiceStopped: Bool = true
    ) {
        guard catalog.hasScreenCapturePermission == true else {
            if clearDisplaysWhenPermissionDenied {
                Task { await self.submitRefresh(.permissionChanged, replayRegistration: false) }
            } else {
                Task { await self.catalogService.cancelRefresh(owner: self.refreshOwner) }
            }
            return
        }
        guard dependencies.sharingQueries.isWebServiceRunning() else {
            _ = clearDisplaysWhenServiceStopped
            Task { await self.catalogService.cancelRefresh(owner: self.refreshOwner) }
            return
        }
        Task { await self.submitRefresh(.serviceBecameRunning) }
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
            _ = await submitRefresh(.serviceBecameRunning)
        }
    }

    func stopService() {
        Task { await catalogService.cancelRefresh(owner: refreshOwner) }
        dependencies.sharingActions.stopWebService()
        syncForCurrentState()
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        catalogService.openScreenCapturePrivacySettings(openURL: openURL)
    }

    func requestScreenCapturePermission() {
        let granted = catalogService.requestPermission()

        AppLog.capture.notice(
            "Screen capture permission request (sharing): requestResult=\((self.catalog.lastRequestPermission ?? false), privacy: .public), preflightResult=\(granted, privacy: .public)"
        )

        if !granted {
            Task {
                await catalogService.clearSnapshotForDeniedPermission(
                    loadErrorMessage: String(localized: "Failed to load displays. Check permission and try again.")
                )
            }
            AppLog.capture.notice("Screen capture permission request denied (sharing).")
            return
        }
        syncForCurrentState()
    }

    func refreshPermissionAndMaybeLoad() {
        let granted = catalogService.refreshPermission()
        if !granted {
            Task { await self.submitRefresh(.permissionChanged, replayRegistration: false) }
            return
        }
        syncForCurrentState(clearDisplaysWhenServiceStopped: false)
    }

    func loadDisplaysIfNeeded() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        Task { await self.submitRefresh(.serviceBecameRunning) }
    }

    func loadDisplays() {
        Task { await self.submitRefresh(.userForcedRefresh) }
    }

    func refreshDisplays() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        Task { await self.submitRefresh(.userForcedRefresh) }
    }

    func refreshDisplaysBackgroundSafe() {
        guard dependencies.sharingQueries.isWebServiceRunning() else { return }
        guard !catalog.isLoadingDisplays else { return }
        Task { await self.submitRefresh(.topologyChanged) }
    }

    func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        catalogService.visibleDisplays(from: displays)
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        dependencies.sharingQueries.isStartingDisplayID(displayID)
    }

    func startSharing(display: SCDisplay) async {
        guard !isStarting(displayID: display.displayID) else { return }

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
            let outcome = try await dependencies.sharingActions.beginSharing(display)
            if case .invalidated = outcome {
                return
            }
        } catch {
            dependencies.sharingActions.stopSharing(display.displayID)
            AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
            presentError(
                title: String(localized: "Share Failed"),
                message: AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to start sharing."))
            )
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
        Task { await catalogService.cancelRefresh(owner: refreshOwner) }
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

    @discardableResult
    private func submitRefresh(
        _ intent: RefreshIntent,
        replayRegistration: Bool = true
    ) async -> ScreenCaptureCatalogRefreshResult {
        let result = await catalogService.submitRefresh(intent: intent, owner: refreshOwner)
        if replayRegistration, dependencies.sharingQueries.isWebServiceRunning() {
            switch result {
            case .reloadedSnapshot, .reusedSnapshot:
                replayShareableDisplaysIfAvailable()
            case .clearedSnapshot, .failed:
                break
            }
        }
        return result
    }

    private func replayShareableDisplaysIfAvailable() {
        guard let displays = catalog.displays else { return }
        registerShareableDisplays(displays)
    }
}
