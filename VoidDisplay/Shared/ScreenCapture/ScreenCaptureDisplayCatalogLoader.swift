import Foundation
import OSLog
import ScreenCaptureKit

@MainActor
final class ScreenCaptureDisplayCatalogLoader {
    typealias LoadShareableDisplays = @Sendable () async throws -> [SCDisplay]
    typealias OnDisplaysLoaded = @MainActor ([SCDisplay]) -> Void

    struct RuntimeScenarioProbe {
        var shouldShortCircuitDisplayLoadAsPermissionDenied: @MainActor () -> Bool

        static let live = Self(
            shouldShortCircuitDisplayLoadAsPermissionDenied: {
                UITestRuntime.isEnabled && UITestRuntime.scenario == .permissionDenied
            }
        )
    }

    let state: ScreenCaptureDisplayCatalogState

    private let permissionProvider: any ScreenCapturePermissionProvider
    // Stored for testability and feature-specific injection. Callers should avoid creating
    // long-lived retain cycles inside this closure if the loader is ever shared beyond one VM.
    private let loadShareableDisplays: LoadShareableDisplays
    private let loadFailureMessage: String
    private let logOperation: String
    private let logger: Logger
    private let runtimeScenarioProbe: RuntimeScenarioProbe
    private var displayLoadTask: Task<Void, Never>?
    private var activeDisplayLoadRequestID: UInt64?
    private var nextDisplayLoadRequestID: UInt64 = 0

    convenience init(
        state: ScreenCaptureDisplayCatalogState? = nil,
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: LoadShareableDisplays? = nil,
        loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
        logOperation: String,
        logger: Logger
    ) {
        self.init(
            state: state,
            permissionProvider: permissionProvider,
            loadShareableDisplays: loadShareableDisplays,
            loadFailureMessage: loadFailureMessage,
            logOperation: logOperation,
            logger: logger,
            runtimeScenarioProbe: .live
        )
    }

    init(
        state: ScreenCaptureDisplayCatalogState? = nil,
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: LoadShareableDisplays? = nil,
        loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
        logOperation: String,
        logger: Logger,
        runtimeScenarioProbe: RuntimeScenarioProbe
    ) {
        self.state = state ?? ScreenCaptureDisplayCatalogState()
        self.permissionProvider = permissionProvider ?? ScreenCapturePermissionProviderFactory.makeDefault()
        self.loadShareableDisplays = loadShareableDisplays ?? {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return content.displays
        }
        self.loadFailureMessage = loadFailureMessage
        self.logOperation = logOperation
        self.logger = logger
        self.runtimeScenarioProbe = runtimeScenarioProbe
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    @discardableResult
    func requestPermission() -> Bool {
        let requestResult = permissionProvider.request()
        state.lastRequestPermission = requestResult

        let preflightResult = permissionProvider.preflight()
        state.hasScreenCapturePermission = preflightResult
        state.lastPreflightPermission = preflightResult
        return preflightResult
    }

    @discardableResult
    func refreshPermission() -> Bool {
        let granted = permissionProvider.preflight()
        state.hasScreenCapturePermission = granted
        state.lastPreflightPermission = granted
        return granted
    }

    func loadDisplaysIfNeeded(onLoaded: @escaping OnDisplaysLoaded = { _ in }) {
        guard !state.isLoadingDisplays, state.displays == nil else { return }
        loadDisplays(onLoaded: onLoaded)
    }

    func loadDisplays(onLoaded: @escaping OnDisplaysLoaded = { _ in }) {
        if runtimeScenarioProbe.shouldShortCircuitDisplayLoadAsPermissionDenied() {
            cancelInFlightDisplayLoad()
            state.hasScreenCapturePermission = false
            state.lastPreflightPermission = false
            state.displays = nil
            return
        }

        displayLoadTask?.cancel()
        displayLoadTask = nil
        let requestID = nextDisplayLoadRequestID &+ 1
        nextDisplayLoadRequestID = requestID
        activeDisplayLoadRequestID = requestID
        state.isLoadingDisplays = true
        state.loadErrorMessage = nil
        state.lastLoadError = nil
        state.displays = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let shareableDisplays = try await self.loadShareableDisplays()
                await MainActor.run {
                    guard self.canCommitDisplayLoadResult(requestID: requestID) else { return }
                    self.state.displays = shareableDisplays
                    self.state.hasScreenCapturePermission = true
                    self.state.lastPreflightPermission = true
                    onLoaded(shareableDisplays)
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
                    AppErrorMapper.logFailure(self.logOperation, error: error, logger: self.logger)
                    self.state.loadErrorMessage = self.loadFailureMessage
                    self.state.lastLoadError = .init(
                        domain: nsError.domain,
                        code: nsError.code,
                        description: nsError.localizedDescription,
                        failureReason: nsError.localizedFailureReason,
                        recoverySuggestion: nsError.localizedRecoverySuggestion
                    )
                    self.state.displays = nil
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
        state.isLoadingDisplays = false
    }

    func clearDisplaysAndCancel() {
        cancelInFlightDisplayLoad()
        state.displays = nil
    }

    private func canCommitDisplayLoadResult(requestID: UInt64) -> Bool {
        activeDisplayLoadRequestID == requestID && !Task.isCancelled
    }

    private func finishDisplayLoadRequestIfCurrent(requestID: UInt64) {
        guard activeDisplayLoadRequestID == requestID else { return }
        activeDisplayLoadRequestID = nil
        state.isLoadingDisplays = false
        displayLoadTask = nil
    }
}
