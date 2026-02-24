import Foundation
import ScreenCaptureKit
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class ShareViewModel {
    struct LoadErrorInfo: Equatable {
        var domain: String
        var code: Int
        var description: String
        var failureReason: String?
        var recoverySuggestion: String?
    }

    var hasScreenCapturePermission: Bool?
    var lastPreflightPermission: Bool?
    var lastRequestPermission: Bool?
    var loadErrorMessage: String?
    var lastLoadError: LoadErrorInfo?
    var showDebugInfo = false

    var displays: [SCDisplay]?
    var isLoadingDisplays = false
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    var showOpenPageError = false
    var openPageErrorMessage = ""
    private let permissionProvider: any ScreenCapturePermissionProvider
    private let loadShareableDisplays: @Sendable () async throws -> [SCDisplay]
    private let makeScreenCaptureSession: @MainActor @Sendable (SCDisplay) async -> ScreenCaptureSession
    @ObservationIgnored private var displayLoadTask: Task<Void, Never>?
    @ObservationIgnored private var activeDisplayLoadRequestID: UInt64?
    @ObservationIgnored private var nextDisplayLoadRequestID: UInt64 = 0

    init(
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: (@Sendable () async throws -> [SCDisplay])? = nil,
        makeScreenCaptureSession: (@MainActor @Sendable (SCDisplay) async -> ScreenCaptureSession)? = nil
    ) {
        self.permissionProvider = permissionProvider ?? ScreenCapturePermissionProviderFactory.makeDefault()
        self.loadShareableDisplays = loadShareableDisplays ?? {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return content.displays
        }
        self.makeScreenCaptureSession = makeScreenCaptureSession ?? { display in
            await createScreenCapture(display: display)
        }
    }

    func syncForCurrentState(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        guard hasScreenCapturePermission == true else {
            cancelInFlightDisplayLoad()
            displays = nil
            return
        }
        guard sharing.isWebServiceRunning else {
            cancelInFlightDisplayLoad()
            displays = nil
            return
        }
        loadDisplaysIfNeeded(sharing: sharing, virtualDisplay: virtualDisplay)
    }

    func startService(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        Task { @MainActor in
            guard await sharing.startWebService() else {
                AppLog.sharing.error("Start service failed.")
                presentError(String(localized: "Failed to start web service."))
                return
            }
            syncForCurrentState(sharing: sharing, virtualDisplay: virtualDisplay)
        }
    }

    func stopService(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        cancelInFlightDisplayLoad()
        sharing.stopWebService()
        syncForCurrentState(sharing: sharing, virtualDisplay: virtualDisplay)
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    func requestScreenCapturePermission(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        let requestResult = permissionProvider.request()
        lastRequestPermission = requestResult

        let preflightResult = permissionProvider.preflight()
        hasScreenCapturePermission = preflightResult
        lastPreflightPermission = preflightResult

        AppLog.capture.notice(
            "Screen capture permission request (sharing): requestResult=\(requestResult, privacy: .public), preflightResult=\(preflightResult, privacy: .public)"
        )

        if !preflightResult {
            cancelInFlightDisplayLoad()
            displays = nil
            loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
            AppLog.capture.notice("Screen capture permission request denied (sharing).")
            return
        }
        syncForCurrentState(sharing: sharing, virtualDisplay: virtualDisplay)
    }

    func refreshPermissionAndMaybeLoad(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        let granted = permissionProvider.preflight()
        hasScreenCapturePermission = granted
        lastPreflightPermission = granted
        if !granted {
            cancelInFlightDisplayLoad()
            displays = nil
            return
        }
        syncForCurrentState(sharing: sharing, virtualDisplay: virtualDisplay)
    }

    func loadDisplaysIfNeeded(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        guard !isLoadingDisplays, displays == nil else { return }
        loadDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
    }

    func loadDisplays(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        if UITestRuntime.isEnabled, UITestRuntime.scenario == .permissionDenied {
            cancelInFlightDisplayLoad()
            hasScreenCapturePermission = false
            lastPreflightPermission = false
            displays = nil
            return
        }

        displayLoadTask?.cancel()
        displayLoadTask = nil
        let requestID = nextDisplayLoadRequestID &+ 1
        nextDisplayLoadRequestID = requestID
        activeDisplayLoadRequestID = requestID
        isLoadingDisplays = true
        loadErrorMessage = nil
        lastLoadError = nil
        displays = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let shareableDisplays = try await self.loadShareableDisplays()
                await MainActor.run {
                    guard self.canCommitDisplayLoadResult(requestID: requestID) else { return }
                    self.displays = shareableDisplays
                    self.hasScreenCapturePermission = true
                    self.lastPreflightPermission = true
                    sharing.registerShareableDisplays(shareableDisplays) { displayID in
                        virtualDisplay.virtualSerialForManagedDisplay(displayID)
                    }
                    self.finishDisplayLoadRequestIfCurrent(requestID: requestID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishDisplayLoadRequestIfCurrent(requestID: requestID)
                }
            } catch {
                let nsError = error as NSError
                await MainActor.run {
                    guard self.canCommitDisplayLoadResult(requestID: requestID) else { return }
                    AppErrorMapper.logFailure("Load shareable displays (sharing)", error: error, logger: AppLog.capture)
                    self.loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
                    self.lastLoadError = .init(
                        domain: nsError.domain,
                        code: nsError.code,
                        description: nsError.localizedDescription,
                        failureReason: nsError.localizedFailureReason,
                        recoverySuggestion: nsError.localizedRecoverySuggestion
                    )
                    self.displays = nil
                    self.finishDisplayLoadRequestIfCurrent(requestID: requestID)
                }
            }
        }
        displayLoadTask = task
    }

    func refreshDisplays(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) {
        guard sharing.isWebServiceRunning else { return }
        loadDisplays(sharing: sharing, virtualDisplay: virtualDisplay)
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

    func startSharing(display: SCDisplay, sharing: SharingController) async {
        _ = await withDisplayStartLock(displayID: display.displayID) {
            let ready: Bool
            if sharing.isWebServiceRunning {
                ready = true
            } else {
                ready = await sharing.startWebService()
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
                sharing.beginSharing(
                    displayID: display.displayID,
                    stream: captureSession.stream,
                    output: stream,
                    delegate: captureSession.delegate
                )
            } catch {
                sharing.stopSharing(displayID: display.displayID)
                AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
                presentError(AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to start sharing.")))
            }
        }
    }

    func stopSharing(displayID: CGDirectDisplayID, sharing: SharingController) {
        sharing.stopSharing(displayID: displayID)
    }

    func sharePageAddress(for displayID: CGDirectDisplayID, sharing: SharingController) -> String? {
        sharing.sharePageAddress(for: displayID)
    }

    func clearError() {
        showOpenPageError = false
    }

    func cancelInFlightDisplayLoad() {
        displayLoadTask?.cancel()
        displayLoadTask = nil
        activeDisplayLoadRequestID = nil
        isLoadingDisplays = false
    }

    private func presentError(_ message: String) {
        openPageErrorMessage = message
        showOpenPageError = true
    }

    private func canCommitDisplayLoadResult(requestID: UInt64) -> Bool {
        activeDisplayLoadRequestID == requestID && !Task.isCancelled
    }

    private func finishDisplayLoadRequestIfCurrent(requestID: UInt64) {
        guard activeDisplayLoadRequestID == requestID else { return }
        activeDisplayLoadRequestID = nil
        isLoadingDisplays = false
        displayLoadTask = nil
    }
}
