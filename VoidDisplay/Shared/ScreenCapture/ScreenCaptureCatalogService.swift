import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
@preconcurrency import ScreenCaptureKit

typealias ScreenCaptureDisplayTopologySignature = [ScreenCaptureDisplayTopologySignatureEntry]

struct ScreenCaptureDisplayTopologySignatureEntry: Sendable, Equatable, Hashable {
    let displayID: CGDirectDisplayID
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRateMilliHertz: Int?
    let mirrorsDisplayID: CGDirectDisplayID?

    init(
        displayID: CGDirectDisplayID,
        isMain: Bool = false,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        refreshRateMilliHertz: Int? = nil,
        mirrorsDisplayID: CGDirectDisplayID? = nil
    ) {
        self.displayID = displayID
        self.isMain = isMain
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateMilliHertz = refreshRateMilliHertz
        self.mirrorsDisplayID = mirrorsDisplayID
    }

    static func current(displayID: CGDirectDisplayID) -> Self {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let refreshRateMilliHertz: Int? = {
            guard let mode else { return nil }
            let refreshRate = mode.refreshRate
            guard refreshRate > 0 else { return nil }
            return Int((refreshRate * 1_000).rounded())
        }()
        let mirrorsDisplayID: CGDirectDisplayID? = {
            let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
            guard mirroredDisplayID != kCGNullDirectDisplay else { return nil }
            guard mirroredDisplayID != CGDirectDisplayID.max else { return nil }
            return mirroredDisplayID
        }()
        return .init(
            displayID: displayID,
            isMain: CGDisplayIsMain(displayID) > 0,
            pixelWidth: max(0, CGDisplayPixelsWide(displayID)),
            pixelHeight: max(0, CGDisplayPixelsHigh(displayID)),
            refreshRateMilliHertz: refreshRateMilliHertz,
            mirrorsDisplayID: mirrorsDisplayID
        )
    }
}

enum ScreenCaptureDisplayTopologySignatureResolver {
    @MainActor
    static func current(
        activeDisplayIDsProvider: () -> Set<CGDirectDisplayID>
    ) -> ScreenCaptureDisplayTopologySignature {
        activeDisplayIDsProvider()
            .sorted()
            .map(ScreenCaptureDisplayTopologySignatureEntry.current(displayID:))
    }
}

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
    var lastLoadedActiveDisplayTopologySignature: ScreenCaptureDisplayTopologySignature?
    var isLoadingDisplays = false
    var loadErrorMessage: String?
    var lastLoadError: ScreenCaptureDisplayCatalogLoadErrorInfo?
    var showDebugInfo = false
    var lastRefreshResult: ScreenCaptureCatalogRefreshResult?
}

@MainActor
final class ScreenCaptureCatalogService {
    private enum CommitResolution {
        case completed(ScreenCaptureCatalogRefreshResult)
        case retry
    }

    struct RefreshOwner: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    typealias LoadShareableDisplays = @MainActor () async throws -> [SCDisplay]
    typealias ActiveDisplayIDsProvider = @MainActor () -> Set<CGDirectDisplayID>

    struct Dependencies {
        var permissionProvider: any ScreenCapturePermissionProvider
        var loadShareableDisplays: LoadShareableDisplays
        var activeDisplayIDsProvider: ActiveDisplayIDsProvider
        var displayTopologySignatureProvider: @MainActor () -> ScreenCaptureDisplayTopologySignature
        var loadFailureMessage: String
        var logOperation: String
        var logger: Logger
        var runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe

        static func live(
            loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
            logOperation: String = "Load shareable displays",
            logger: Logger = AppLog.capture
        ) -> Self {
            let activeDisplayIDsProvider = ScreenCaptureActiveDisplayIDsProviderFactory.makeDefault()
            return .init(
                permissionProvider: ScreenCapturePermissionProviderFactory.makeDefault(),
                loadShareableDisplays: ScreenCaptureShareableDisplayLoaderFactory.makeDefault(),
                activeDisplayIDsProvider: activeDisplayIDsProvider,
                displayTopologySignatureProvider: {
                    ScreenCaptureDisplayTopologySignatureResolver.current(
                        activeDisplayIDsProvider: activeDisplayIDsProvider
                    )
                },
                loadFailureMessage: loadFailureMessage,
                logOperation: logOperation,
                logger: logger,
                runtimeScenarioProbe: .live
            )
        }
    }

    let store: ScreenCaptureCatalogStore

    nonisolated private static let maxCommitSignatureRetryCount = 3

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
                    try await dependencies.loadShareableDisplays().map(SendableDisplay.init)
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
        displayTopologySignatureProvider: (@MainActor () -> ScreenCaptureDisplayTopologySignature)? = nil,
        loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
        logOperation: String = "Load shareable displays",
        logger: Logger = AppLog.capture,
        runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe = .live
    ) {
        let resolvedActiveDisplayIDsProvider = activeDisplayIDsProvider
            ?? ScreenCaptureActiveDisplayIDsProviderFactory.makeDefault()
        self.init(
            store: store,
            dependencies: .init(
                permissionProvider: permissionProvider ?? ScreenCapturePermissionProviderFactory.makeDefault(),
                loadShareableDisplays: loadShareableDisplays
                    ?? ScreenCaptureShareableDisplayLoaderFactory.makeDefault(),
                activeDisplayIDsProvider: resolvedActiveDisplayIDsProvider,
                displayTopologySignatureProvider: displayTopologySignatureProvider ?? {
                    ScreenCaptureDisplayTopologySignatureResolver.current(
                        activeDisplayIDsProvider: resolvedActiveDisplayIDsProvider
                    )
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

    func currentActiveDisplayTopologySignature() -> ScreenCaptureDisplayTopologySignature {
        dependencies.displayTopologySignatureProvider()
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
        var staleCommitRetryCount = 0
        var clearedSnapshotForCurrentRequest = false

        while true {
            let permissionGranted = refreshPermission()
            let requestSignature = currentActiveDisplayTopologySignature()
            let request = CatalogRefreshCoordinator.Request(
                intent: intent,
                permissionGranted: permissionGranted,
                currentTopologySignature: requestSignature,
                cachedTopologySignature: store.lastLoadedActiveDisplayTopologySignature,
                hasCachedDisplays: store.displays != nil,
                ownerID: owner?.id
            )

            switch await coordinator.prepare(request: request) {
            case .reusedSnapshot:
                store.lastRefreshResult = .reusedSnapshot
                return .reusedSnapshot
            case .clearedSnapshot:
                applyClearedSnapshot(signature: requestSignature)
                return .clearedSnapshot
            case .failed:
                store.isLoadingDisplays = false
                store.lastRefreshResult = .failed
                return .failed
            case .awaitInFlight(let loadID):
                store.isLoadingDisplays = true
                let execution = await coordinator.executeLoad(loadID: loadID)
                switch resolveCommit(
                    execution: execution,
                    requestSignature: requestSignature,
                    staleCommitRetryCount: &staleCommitRetryCount
                ) {
                case .completed(let result):
                    return result
                case .retry:
                    continue
                }
            case .execute(let loadID, let clearsSnapshotFirst):
                store.isLoadingDisplays = true
                store.loadErrorMessage = nil
                store.lastLoadError = nil
                if clearsSnapshotFirst, !clearedSnapshotForCurrentRequest {
                    store.displays = nil
                    clearedSnapshotForCurrentRequest = true
                }

                let execution = await coordinator.executeLoad(loadID: loadID)
                switch resolveCommit(
                    execution: execution,
                    requestSignature: requestSignature,
                    staleCommitRetryCount: &staleCommitRetryCount
                ) {
                case .completed(let result):
                    return result
                case .retry:
                    continue
                }
            }
        }
    }

    private func applyClearedSnapshot(signature: ScreenCaptureDisplayTopologySignature) {
        store.displays = nil
        store.hasScreenCapturePermission = false
        store.lastPreflightPermission = false
        store.lastLoadedActiveDisplayTopologySignature = signature
        store.isLoadingDisplays = false
        store.loadErrorMessage = nil
        store.lastLoadError = nil
        store.lastRefreshResult = .clearedSnapshot
    }

    private func resolveCommit(
        execution: CatalogRefreshCoordinator.ExecutionResult,
        requestSignature: ScreenCaptureDisplayTopologySignature,
        staleCommitRetryCount: inout Int
    ) -> CommitResolution {
        switch execution {
        case .reloadedSnapshot(let displays):
            let commitSignature = currentActiveDisplayTopologySignature()
            guard commitSignature == requestSignature else {
                dependencies.logger.warning(
                    "Discarding stale display snapshot before commit because topology changed during refresh."
                )
                guard staleCommitRetryCount < Self.maxCommitSignatureRetryCount else {
                    dependencies.logger.error(
                        "Abandoning display refresh after repeated topology changes prevented a stable commit."
                    )
                    store.isLoadingDisplays = false
                    store.lastRefreshResult = .failed
                    return .completed(.failed)
                }
                staleCommitRetryCount += 1
                return .retry
            }
            store.displays = displays.map(\.value)
            store.hasScreenCapturePermission = true
            store.lastPreflightPermission = true
            store.lastLoadedActiveDisplayTopologySignature = commitSignature
            store.isLoadingDisplays = false
            store.loadErrorMessage = nil
            store.lastLoadError = nil
            store.lastRefreshResult = .reloadedSnapshot
            return .completed(.reloadedSnapshot)
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
            return .completed(.failed)
        case .clearedSnapshot:
            applyClearedSnapshot(signature: requestSignature)
            return .completed(.clearedSnapshot)
        case .failedSuperseded:
            return .completed(.failed)
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
        let currentTopologySignature: ScreenCaptureDisplayTopologySignature
        let cachedTopologySignature: ScreenCaptureDisplayTopologySignature?
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

    private let loadShareableDisplays: @Sendable () async throws -> [SendableDisplay]
    private let runtimeScenarioProbe: ScreenCaptureDisplayCatalogLoader.RuntimeScenarioProbe
    private var nextLoadID: UInt64 = 0
    private var activeLoadID: UInt64?
    private var activeOwnerID: UUID?
    private var activeTask: Task<[SendableDisplay], Error>?
    private var waiterCountsByLoadID: [UInt64: Int] = [:]

    init(
        loadShareableDisplays: @escaping @Sendable () async throws -> [SendableDisplay],
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
                    return try await loadShareableDisplays()
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
