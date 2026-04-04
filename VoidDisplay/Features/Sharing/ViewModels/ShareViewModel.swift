import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Observation
import OSLog

@MainActor
@Observable
final class ShareViewModel {
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
        self.servicePortInput = String(dependencies.sharingQueries.preferredWebServicePort())
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
        }
    }

    func stopService() {
        dependencies.sharingActions.stopWebService()
    }

    func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
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

    private func presentError(title: String, message: String) {
        userFacingAlert = UserFacingAlertState(title: title, message: message)
    }

    private func presentPortInputError(_ message: String) {
        portInputErrorMessage = message
    }
}
