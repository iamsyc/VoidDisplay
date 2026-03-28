import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureCatalogRefreshIntent: Sendable, Equatable {
    case permissionChanged
    case topologyChanged
    case serviceBecameRunning
    case userForcedRefresh

}

enum ScreenCaptureCatalogRefreshResult: Sendable, Equatable {
    case reloadedSnapshot
    case reusedSnapshot
    case clearedSnapshot
    case failed
}

@MainActor
@Observable
final class ScreenCaptureCatalogStore {
    var displays: [SCDisplay]?
    var hasScreenCapturePermission: Bool?
    var lastPreflightPermission: Bool?
    var lastRequestPermission: Bool?
    var lastLoadedActiveDisplayTopologySignature: [CGDirectDisplayID]?
    var isLoadingDisplays = false
    var loadErrorMessage: String?
    var lastLoadError: ScreenCaptureDisplayCatalogLoadErrorInfo?
    var showDebugInfo = false
    var lastRefreshResult: ScreenCaptureCatalogRefreshResult?
}

@MainActor
final class ScreenCaptureCatalogService {
    struct RefreshOwner: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    typealias LoadShareableDisplays = @MainActor () async throws -> [SCDisplay]
    typealias ActiveDisplayIDsProvider = @MainActor () -> Set<CGDirectDisplayID>

    struct Dependencies {
        var permissionProvider: any ScreenCapturePermissionProvider
        var loadShareableDisplays: LoadShareableDisplays
        var activeDisplayIDsProvider: ActiveDisplayIDsProvider
        var loadFailureMessage: String
        var logOperation: String
        var logger: Logger
        var runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe

        static func live(
            loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
            logOperation: String = "Load shareable displays",
            logger: Logger = AppLog.capture
        ) -> Self {
            .init(
                permissionProvider: ScreenCapturePermissionProviderFactory.makeDefault(),
                loadShareableDisplays: {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    )
                    return content.displays
                },
                activeDisplayIDsProvider: {
                    Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
                },
                loadFailureMessage: loadFailureMessage,
                logOperation: logOperation,
                logger: logger,
                runtimeScenarioProbe: .live
            )
        }
    }

    let store: ScreenCaptureCatalogStore

    private let dependencies: Dependencies
    private let coordinator: CatalogRefreshCoordinator

    init(
        store: ScreenCaptureCatalogStore? = nil,
        dependencies: Dependencies
    ) {
        let resolvedStore = store ?? ScreenCaptureCatalogStore()
        self.store = resolvedStore
        self.dependencies = dependencies
        self.coordinator = CatalogRefreshCoordinator(
            loadShareableDisplays: {
                try await Task { @MainActor in
                    try await dependencies.loadShareableDisplays()
                }.value
            },
            runtimeScenarioProbe: dependencies.runtimeScenarioProbe
        )
    }

    convenience init(
        store: ScreenCaptureCatalogStore? = nil,
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: LoadShareableDisplays? = nil,
        activeDisplayIDsProvider: ActiveDisplayIDsProvider? = nil,
        loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
        logOperation: String = "Load shareable displays",
        logger: Logger = AppLog.capture,
        runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe = .live
    ) {
        self.init(
            store: store,
            dependencies: .init(
                permissionProvider: permissionProvider ?? ScreenCapturePermissionProviderFactory.makeDefault(),
                loadShareableDisplays: loadShareableDisplays ?? {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    )
                    return content.displays
                },
                activeDisplayIDsProvider: activeDisplayIDsProvider ?? {
                    Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
                },
                loadFailureMessage: loadFailureMessage,
                logOperation: logOperation,
                logger: logger,
                runtimeScenarioProbe: runtimeScenarioProbe
            )
        )
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
        let requestResult = dependencies.permissionProvider.request()
        store.lastRequestPermission = requestResult

        let preflightResult = dependencies.permissionProvider.preflight()
        store.hasScreenCapturePermission = preflightResult
        store.lastPreflightPermission = preflightResult
        return preflightResult
    }

    @discardableResult
    func refreshPermission() -> Bool {
        let granted = dependencies.permissionProvider.preflight()
        store.hasScreenCapturePermission = granted
        store.lastPreflightPermission = granted
        return granted
    }

    func currentActiveDisplayTopologySignature() -> [CGDirectDisplayID] {
        dependencies.activeDisplayIDsProvider().sorted()
    }

    func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = dependencies.activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage: String? = nil) async {
        await coordinator.cancelActiveRefresh()
        applyClearedSnapshot(signature: currentActiveDisplayTopologySignature())
        store.loadErrorMessage = loadErrorMessage
    }

    func cancelRefresh(owner: RefreshOwner? = nil) async {
        let cancellation = await coordinator.cancelActiveRefresh(ownedBy: owner?.id)
        if cancellation != .ignoredOtherOwner {
            store.isLoadingDisplays = false
        }
    }

    @discardableResult
    func submitRefresh(
        intent: ScreenCaptureCatalogRefreshIntent,
        owner: RefreshOwner? = nil
    ) async -> ScreenCaptureCatalogRefreshResult {
        let permissionGranted = refreshPermission()
        let currentSignature = currentActiveDisplayTopologySignature()
        let request = CatalogRefreshCoordinator.Request(
            intent: intent,
            permissionGranted: permissionGranted,
            currentTopologySignature: currentSignature,
            cachedTopologySignature: store.lastLoadedActiveDisplayTopologySignature,
            hasCachedDisplays: store.displays != nil,
            ownerID: owner?.id
        )

        switch await coordinator.prepare(request: request) {
        case .reusedSnapshot:
            store.lastRefreshResult = .reusedSnapshot
            return .reusedSnapshot
        case .clearedSnapshot:
            applyClearedSnapshot(signature: currentSignature)
            return .clearedSnapshot
        case .failed:
            store.lastRefreshResult = .failed
            return .failed
        case .awaitInFlight(let loadID):
            store.isLoadingDisplays = true
            let execution = await coordinator.executeLoad(loadID: loadID)
            return commit(execution: execution, signature: currentSignature)
        case .execute(let loadID, let clearsSnapshotFirst):
            store.isLoadingDisplays = true
            store.loadErrorMessage = nil
            store.lastLoadError = nil
            if clearsSnapshotFirst {
                store.displays = nil
            }

            let execution = await coordinator.executeLoad(loadID: loadID)
            return commit(execution: execution, signature: currentSignature)
        }
    }

    private func applyClearedSnapshot(signature: [CGDirectDisplayID]) {
        store.displays = nil
        store.hasScreenCapturePermission = false
        store.lastPreflightPermission = false
        store.lastLoadedActiveDisplayTopologySignature = signature
        store.isLoadingDisplays = false
        store.loadErrorMessage = nil
        store.lastLoadError = nil
        store.lastRefreshResult = .clearedSnapshot
    }

    private func commit(
        execution: CatalogRefreshCoordinator.ExecutionResult,
        signature: [CGDirectDisplayID]
    ) -> ScreenCaptureCatalogRefreshResult {
        switch execution {
        case .reloadedSnapshot(let displays):
            store.displays = displays.map(\.value)
            store.hasScreenCapturePermission = true
            store.lastPreflightPermission = true
            store.lastLoadedActiveDisplayTopologySignature = signature
            store.isLoadingDisplays = false
            store.loadErrorMessage = nil
            store.lastLoadError = nil
            store.lastRefreshResult = .reloadedSnapshot
            return .reloadedSnapshot
        case .failed(let error, let shouldClearDisplays):
            let nsError = error as NSError
            AppErrorMapper.logFailure(
                dependencies.logOperation,
                error: error,
                logger: dependencies.logger
            )
            store.isLoadingDisplays = false
            store.loadErrorMessage = dependencies.loadFailureMessage
            store.lastLoadError = .init(
                domain: nsError.domain,
                code: nsError.code,
                description: nsError.localizedDescription,
                failureReason: nsError.localizedFailureReason,
                recoverySuggestion: nsError.localizedRecoverySuggestion
            )
            if shouldClearDisplays {
                store.displays = nil
            }
            store.lastRefreshResult = .failed
            return .failed
        case .clearedSnapshot:
            applyClearedSnapshot(signature: signature)
            return .clearedSnapshot
        case .failedSuperseded:
            return .failed
        }
    }
}

actor CatalogRefreshCoordinator {
    enum CancelResult: Sendable, Equatable {
        case cancelledActiveRequest
        case idle
        case ignoredOtherOwner
    }

    struct Request: Sendable {
        let intent: ScreenCaptureCatalogRefreshIntent
        let permissionGranted: Bool
        let currentTopologySignature: [CGDirectDisplayID]
        let cachedTopologySignature: [CGDirectDisplayID]?
        let hasCachedDisplays: Bool
        let ownerID: UUID?
    }

    enum PrepareResult: Sendable, Equatable {
        case execute(loadID: UInt64, clearsSnapshotFirst: Bool)
        case awaitInFlight(loadID: UInt64)
        case reusedSnapshot
        case clearedSnapshot
        case failed
    }

    enum ExecutionResult: Sendable {
        case reloadedSnapshot([SendableDisplay])
        case failed(error: any Error, shouldClearDisplays: Bool)
        case clearedSnapshot
        case failedSuperseded
    }

    private let loadShareableDisplays: @Sendable () async throws -> [SCDisplay]
    private let runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe
    private var nextLoadID: UInt64 = 0
    private var activeLoadID: UInt64?
    private var activeOwnerID: UUID?
    private var activeTask: Task<[SendableDisplay], Error>?
    private var waiterCountsByLoadID: [UInt64: Int] = [:]

    init(
        loadShareableDisplays: @escaping @Sendable () async throws -> [SCDisplay],
        runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe
    ) {
        self.loadShareableDisplays = loadShareableDisplays
        self.runtimeScenarioProbe = runtimeScenarioProbe
    }

    func prepare(request: Request) async -> PrepareResult {
        if await MainActor.run(body: { runtimeScenarioProbe.shouldShortCircuitDisplayLoadAsPermissionDenied() }) {
            cancelActiveRefresh()
            return .clearedSnapshot
        }

        guard request.permissionGranted else {
            cancelActiveRefresh()
            return .clearedSnapshot
        }

        let isForcedRefresh: Bool
        switch request.intent {
        case .userForcedRefresh:
            isForcedRefresh = true
        case .permissionChanged, .topologyChanged, .serviceBecameRunning:
            isForcedRefresh = false
        }

        let canReuseSnapshot =
            !isForcedRefresh &&
            request.hasCachedDisplays &&
            request.cachedTopologySignature == request.currentTopologySignature

        if canReuseSnapshot {
            if let activeLoadID {
                waiterCountsByLoadID[activeLoadID, default: 0] += 1
                return .awaitInFlight(loadID: activeLoadID)
            }
            return .reusedSnapshot
        }

        activeTask?.cancel()
        activeTask = nil
        nextLoadID &+= 1
        let loadID = nextLoadID
        activeLoadID = loadID
        activeOwnerID = request.ownerID
        waiterCountsByLoadID[loadID, default: 0] += 1
        return .execute(loadID: loadID, clearsSnapshotFirst: !request.hasCachedDisplays)
    }

    func executeLoad(loadID: UInt64) async -> ExecutionResult {
        guard waiterCountsByLoadID[loadID] != nil else {
            return .failedSuperseded
        }
        defer { finishWaiting(on: loadID) }

        let task: Task<[SendableDisplay], Error>
        if activeLoadID == loadID {
            if let activeTask {
                task = activeTask
            } else {
                let createdTask = Task<[SendableDisplay], Error> { [loadShareableDisplays, runtimeScenarioProbe] in
                    if await MainActor.run(body: { runtimeScenarioProbe.shouldDelayDisplayLoadForUITest() }) {
                        try await Task.sleep(for: .seconds(3))
                    }
                    return try await loadShareableDisplays().map(SendableDisplay.init)
                }
                activeTask = createdTask
                task = createdTask
            }
        } else {
            return .failedSuperseded
        }

        do {
            let displays = try await task.value
            guard activeLoadID == loadID, !Task.isCancelled else {
                return .failedSuperseded
            }
            return .reloadedSnapshot(displays)
        } catch is CancellationError {
            return .failedSuperseded
        } catch {
            guard activeLoadID == loadID else {
                return .failedSuperseded
            }
            return .failed(error: error, shouldClearDisplays: false)
        }
    }

    func cancelActiveRefresh() {
        activeTask?.cancel()
        activeTask = nil
        activeLoadID = nil
        activeOwnerID = nil
    }

    func cancelActiveRefresh(ownedBy ownerID: UUID?) -> CancelResult {
        guard activeLoadID != nil else { return .idle }
        if let ownerID, activeOwnerID != ownerID {
            return .ignoredOtherOwner
        }
        cancelActiveRefresh()
        return .cancelledActiveRequest
    }

    private func finishWaiting(on loadID: UInt64) {
        guard let waiterCount = waiterCountsByLoadID[loadID] else { return }
        if waiterCount > 1 {
            waiterCountsByLoadID[loadID] = waiterCount - 1
            return
        }

        waiterCountsByLoadID.removeValue(forKey: loadID)
        guard activeLoadID == loadID else { return }
        activeTask = nil
        activeLoadID = nil
        activeOwnerID = nil
    }
}
