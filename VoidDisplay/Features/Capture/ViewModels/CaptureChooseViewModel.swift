import Foundation
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class CaptureChooseViewModel {
    struct LoadErrorInfo: Equatable {
        var domain: String
        var code: Int
        var description: String
        var failureReason: String?
        var recoverySuggestion: String?
    }

    var displays: [SCDisplay]?
    var hasScreenCapturePermission: Bool?
    var lastPreflightPermission: Bool?
    var lastRequestPermission: Bool?
    var isLoadingDisplays = false
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    var loadErrorMessage: String?
    var lastLoadError: LoadErrorInfo?
    var showDebugInfo = false
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

    func isVirtualDisplay(_ display: SCDisplay, virtualDisplay: VirtualDisplayController) -> Bool {
        virtualDisplay.isManagedVirtualDisplay(displayID: display.displayID)
    }

    func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? String(localized: "Monitor")
    }

    func resolutionText(for display: SCDisplay) -> String {
        "\(Int(display.frame.width)) × \(Int(display.frame.height))"
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
        capture: CaptureController,
        virtualDisplay: VirtualDisplayController,
        openWindow: @escaping (UUID) -> Void
    ) async {
        _ = await withDisplayStartLock(displayID: display.displayID) {
            if let existingSession = capture.screenCaptureSessions.first(where: { $0.displayID == display.displayID }) {
                openWindow(existingSession.id)
                return
            }

            let captureSession = await makeScreenCaptureSession(display)
            let session = ScreenMonitoringSession(
                id: UUID(),
                displayID: display.displayID,
                displayName: displayName(for: display),
                resolutionText: resolutionText(for: display),
                isVirtualDisplay: isVirtualDisplay(display, virtualDisplay: virtualDisplay),
                stream: captureSession.stream,
                delegate: captureSession.delegate,
                state: .starting
            )
            capture.addMonitoringSession(session)
            openWindow(session.id)
        }
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    func requestScreenCapturePermission() {
        let requestResult = permissionProvider.request()
        lastRequestPermission = requestResult

        let preflightResult = permissionProvider.preflight()
        hasScreenCapturePermission = preflightResult
        lastPreflightPermission = preflightResult

        if !preflightResult {
            cancelInFlightDisplayLoad()
            displays = nil
            AppLog.capture.notice("Screen capture permission request denied.")
            return
        }
        loadDisplays()
    }

    func refreshPermissionAndMaybeLoad() {
        let granted = permissionProvider.preflight()
        hasScreenCapturePermission = granted
        lastPreflightPermission = granted
        if !granted {
            cancelInFlightDisplayLoad()
            AppLog.capture.notice("Screen capture permission preflight denied.")
        }
        if granted {
            loadDisplays()
        }
    }

    func loadDisplays() {
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
                    AppErrorMapper.logFailure("Load shareable displays", error: error, logger: AppLog.capture)
                    self.loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
                    self.lastLoadError = .init(
                        domain: nsError.domain,
                        code: nsError.code,
                        description: nsError.localizedDescription,
                        failureReason: nsError.localizedFailureReason,
                        recoverySuggestion: nsError.localizedRecoverySuggestion
                    )
                    self.finishDisplayLoadRequestIfCurrent(requestID: requestID)
                }
            }
        }
        displayLoadTask = task
    }

    func cancelInFlightDisplayLoad() {
        displayLoadTask?.cancel()
        displayLoadTask = nil
        activeDisplayLoadRequestID = nil
        isLoadingDisplays = false
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
