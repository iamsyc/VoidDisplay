import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Observation
import OSLog

@MainActor
@Observable
package final class ShareViewModel {
    package struct SharingQueries {
        package var isWebServiceRunning: @MainActor () -> Bool
        package var activeSharingDisplayCount: @MainActor () -> Int
        package var sharingClientCount: @MainActor () -> Int
        package var isDisplaySharing: @MainActor (CGDirectDisplayID) -> Bool
        package var isStartingDisplayID: @MainActor (CGDirectDisplayID) -> Bool
        package var displayClientCount: @MainActor (CGDirectDisplayID) -> Int
        package var sharePageAddress: @MainActor (CGDirectDisplayID) -> String?
        package var preferredWebServicePort: @MainActor () -> UInt16

        package init(
            isWebServiceRunning: @escaping @MainActor () -> Bool,
            activeSharingDisplayCount: @escaping @MainActor () -> Int,
            sharingClientCount: @escaping @MainActor () -> Int,
            isDisplaySharing: @escaping @MainActor (CGDirectDisplayID) -> Bool,
            isStartingDisplayID: @escaping @MainActor (CGDirectDisplayID) -> Bool,
            displayClientCount: @escaping @MainActor (CGDirectDisplayID) -> Int,
            sharePageAddress: @escaping @MainActor (CGDirectDisplayID) -> String?,
            preferredWebServicePort: @escaping @MainActor () -> UInt16
        ) {
            self.isWebServiceRunning = isWebServiceRunning
            self.activeSharingDisplayCount = activeSharingDisplayCount
            self.sharingClientCount = sharingClientCount
            self.isDisplaySharing = isDisplaySharing
            self.isStartingDisplayID = isStartingDisplayID
            self.displayClientCount = displayClientCount
            self.sharePageAddress = sharePageAddress
            self.preferredWebServicePort = preferredWebServicePort
        }
    }
    package struct SharingActions {
        package var startWebService: @MainActor (UInt16) async -> WebServiceStartResult
        package var stopWebService: @MainActor () -> Void
        package var registerShareableDisplays: @MainActor ([SCDisplay], @escaping (CGDirectDisplayID) -> UInt32?) -> Void
        package var beginSharing: @MainActor (SCDisplay) async throws -> DisplayStartOutcome<Void>
        package var stopSharing: @MainActor (CGDirectDisplayID) -> Void

        package init(
            startWebService: @escaping @MainActor (UInt16) async -> WebServiceStartResult,
            stopWebService: @escaping @MainActor () -> Void,
            registerShareableDisplays: @escaping @MainActor ([SCDisplay], @escaping (CGDirectDisplayID) -> UInt32?) -> Void,
            beginSharing: @escaping @MainActor (SCDisplay) async throws -> DisplayStartOutcome<Void>,
            stopSharing: @escaping @MainActor (CGDirectDisplayID) -> Void
        ) {
            self.startWebService = startWebService
            self.stopWebService = stopWebService
            self.registerShareableDisplays = registerShareableDisplays
            self.beginSharing = beginSharing
            self.stopSharing = stopSharing
        }
    }
    package struct VirtualDisplayQueries {
        package var virtualSerialForManagedDisplay: @MainActor (CGDirectDisplayID) -> UInt32?

        package init(
            virtualSerialForManagedDisplay: @escaping @MainActor (CGDirectDisplayID) -> UInt32?
        ) {
            self.virtualSerialForManagedDisplay = virtualSerialForManagedDisplay
        }
    }
    package struct Dependencies {
        package var sharingQueries: SharingQueries
        package var sharingActions: SharingActions
        package var virtualDisplayQueries: VirtualDisplayQueries

        package init(
            sharingQueries: SharingQueries,
            sharingActions: SharingActions,
            virtualDisplayQueries: VirtualDisplayQueries
        ) {
            self.sharingQueries = sharingQueries
            self.sharingActions = sharingActions
            self.virtualDisplayQueries = virtualDisplayQueries
        }

    }

    package let catalog: ScreenCaptureDisplayCatalogState
    package var servicePortInput = "" {
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
    package var portInputErrorMessage: String?
    package var isStartingService = false
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
        self.servicePortInput = String(dependencies.sharingQueries.preferredWebServicePort())
    }

    package func startService() {
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

    package func stopService() {
        dependencies.sharingActions.stopWebService()
    }

    package func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        dependencies.sharingQueries.isStartingDisplayID(displayID)
    }

    package func isWebServiceRunning() -> Bool {
        dependencies.sharingQueries.isWebServiceRunning()
    }

    package func activeSharingDisplayCount() -> Int {
        dependencies.sharingQueries.activeSharingDisplayCount()
    }

    package func sharingClientCount() -> Int {
        dependencies.sharingQueries.sharingClientCount()
    }

    package func isDisplaySharing(displayID: CGDirectDisplayID) -> Bool {
        dependencies.sharingQueries.isDisplaySharing(displayID)
    }

    package func displayClientCount(for displayID: CGDirectDisplayID) -> Int {
        dependencies.sharingQueries.displayClientCount(displayID)
    }

    package func startSharing(display: SCDisplay) async {
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

    package func stopSharing(displayID: CGDirectDisplayID) {
        dependencies.sharingActions.stopSharing(displayID)
    }

    package func sharePageAddress(for displayID: CGDirectDisplayID) -> String? {
        dependencies.sharingQueries.sharePageAddress(displayID)
    }

    package func dismissAlert() {
        userFacingAlert = nil
    }

    private func presentError(title: String, message: String) {
        userFacingAlert = UserFacingAlertState(title: title, message: message)
    }

    private func presentPortInputError(_ message: String) {
        portInputErrorMessage = message
    }
}
