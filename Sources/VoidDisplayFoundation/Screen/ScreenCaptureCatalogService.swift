import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
@preconcurrency import ScreenCaptureKit

package typealias ScreenCaptureDisplayTopologySignature = [ScreenCaptureDisplayTopologySignatureEntry]
package struct ScreenCaptureDisplayTopologySignatureEntry: Sendable, Equatable, Hashable {
    package let displayID: CGDirectDisplayID
    package let isMain: Bool
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let refreshRateMilliHertz: Int?
    package let mirrorsDisplayID: CGDirectDisplayID?

    package init(
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

    package static func current(displayID: CGDirectDisplayID) -> Self {
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
package enum ScreenCaptureDisplayTopologySignatureResolver {
    @MainActor
    package static func current(
        activeDisplayIDsProvider: () -> Set<CGDirectDisplayID>
    ) -> ScreenCaptureDisplayTopologySignature {
        activeDisplayIDsProvider()
            .sorted()
            .map(ScreenCaptureDisplayTopologySignatureEntry.current(displayID:))
    }
}
package enum ScreenCaptureCatalogRefreshIntent: Sendable, Equatable {
    case permissionChanged
    case topologyChanged
    case serviceBecameRunning
    case userForcedRefresh

}
package enum ScreenCaptureCatalogRefreshResult: Sendable, Equatable {
    case reloadedSnapshot
    case reusedSnapshot
    case clearedSnapshot
    case superseded
    case failed
}

package struct ScreenCaptureCatalogDisplaySnapshot: Sendable, Equatable {
    package let displayID: CGDirectDisplayID
    package let pixelWidth: Int
    package let pixelHeight: Int
}

package struct ScreenCaptureCatalogStateSnapshot: Sendable, Equatable {
    package let hasScreenCapturePermission: Bool?
    package let lastPreflightPermission: Bool?
    package let lastRequestPermission: Bool?
    package let isLoadingDisplays: Bool
    package let hasLoadError: Bool
    package let lastLoadError: ScreenCaptureDisplayCatalogLoadErrorInfo?
    package let loadedDisplays: [ScreenCaptureCatalogDisplaySnapshot]
    package let topologySignature: ScreenCaptureDisplayTopologySignature
}

package struct ScreenCaptureCatalogRefreshSettlement: Sendable, Equatable {
    package let id: UInt64
    package let result: ScreenCaptureCatalogRefreshResult
    package let catalog: ScreenCaptureCatalogStateSnapshot
}

@MainActor
@Observable
package final class ScreenCaptureCatalogStore {
    package var displays: [SCDisplay]?
    package var hasScreenCapturePermission: Bool?
    package var lastPreflightPermission: Bool?
    package var lastRequestPermission: Bool?
    package var lastLoadedActiveDisplayTopologySignature: ScreenCaptureDisplayTopologySignature?
    package var isLoadingDisplays = false
    package var loadErrorMessage: String?
    package var lastLoadError: ScreenCaptureDisplayCatalogLoadErrorInfo?
    package var showDebugInfo = false
    package var lastRefreshResult: ScreenCaptureCatalogRefreshResult?

    package var activeShareableDisplays: [SCDisplay]? {
        guard let displays else { return nil }
        let activeDisplayIDs = Set(
            (lastLoadedActiveDisplayTopologySignature ?? []).map(\.displayID)
        )
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    package init() {}
}

@MainActor
package final class ScreenCaptureCatalogService {
    private enum CommitResolution {
        case completed(ScreenCaptureCatalogRefreshResult)
        case retry
    }
    package typealias LoadShareableDisplays = @MainActor () async throws -> [SCDisplay]
    package typealias ActiveDisplayIDsProvider = @MainActor () -> Set<CGDirectDisplayID>
    package struct Dependencies {
        var permissionProvider: any ScreenCapturePermissionProvider
        var loadShareableDisplays: LoadShareableDisplays
        var displayTopologySignatureProvider: @MainActor () -> ScreenCaptureDisplayTopologySignature
        var loadFailureMessage: String
        var logOperation: String
        var logger: Logger

        static func live(
            loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
            logOperation: String = "Load shareable displays",
            logger: Logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay",
                category: "capture"
            )
        ) -> Self {
            let activeDisplayIDsProvider = ScreenCaptureActiveDisplayIDsProviderFactory.makeDefault()
            return .init(
                permissionProvider: ScreenCapturePermissionProviderFactory.makeDefault(),
                loadShareableDisplays: ScreenCaptureShareableDisplayLoaderFactory.makeDefault(),
                displayTopologySignatureProvider: {
                    ScreenCaptureDisplayTopologySignatureResolver.current(
                        activeDisplayIDsProvider: activeDisplayIDsProvider
                    )
                },
                loadFailureMessage: loadFailureMessage,
                logOperation: logOperation,
                logger: logger
            )
        }
    }

    package let store: ScreenCaptureCatalogStore

    nonisolated private static let maxCommitSignatureRetryCount = 3

    private let dependencies: Dependencies
    private let coordinator: CatalogRefreshCoordinator
    private var activeRefreshSubmissionCount = 0
    private var refreshSettlementVersion: UInt64 = 0
    private var lastRefreshSettlement: ScreenCaptureCatalogRefreshSettlement?
    private var refreshSettlementWaiters: [UUID: RefreshSettlementWaiter] = [:]

    private struct RefreshSettlementWaiter {
        let afterSettlementID: UInt64
        let continuation: CheckedContinuation<ScreenCaptureCatalogRefreshSettlement?, Never>
    }

    package init(
        store: ScreenCaptureCatalogStore? = nil,
        dependencies: Dependencies
    ) {
        let resolvedStore = store ?? ScreenCaptureCatalogStore()
        let loadShareableDisplays = dependencies.loadShareableDisplays
        self.store = resolvedStore
        self.dependencies = dependencies
        self.coordinator = CatalogRefreshCoordinator(
            loadShareableDisplays: { @MainActor in
                try await loadShareableDisplays().map(SendableDisplay.init)
            }
        )
    }

    package convenience init(
        store: ScreenCaptureCatalogStore? = nil,
        permissionProvider: (any ScreenCapturePermissionProvider)? = nil,
        loadShareableDisplays: LoadShareableDisplays? = nil,
        activeDisplayIDsProvider: ActiveDisplayIDsProvider? = nil,
        displayTopologySignatureProvider: (@MainActor () -> ScreenCaptureDisplayTopologySignature)? = nil,
        loadFailureMessage: String = String(localized: "Failed to load displays. Check permission and try again."),
        logOperation: String = "Load shareable displays",
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay",
            category: "capture"
        )
    ) {
        let resolvedActiveDisplayIDsProvider = activeDisplayIDsProvider
            ?? ScreenCaptureActiveDisplayIDsProviderFactory.makeDefault()
        self.init(
            store: store,
            dependencies: .init(
                permissionProvider: permissionProvider ?? ScreenCapturePermissionProviderFactory.makeDefault(),
                loadShareableDisplays: loadShareableDisplays
                    ?? ScreenCaptureShareableDisplayLoaderFactory.makeDefault(),
                displayTopologySignatureProvider: displayTopologySignatureProvider ?? {
                    ScreenCaptureDisplayTopologySignatureResolver.current(
                        activeDisplayIDsProvider: resolvedActiveDisplayIDsProvider
                    )
                },
                loadFailureMessage: loadFailureMessage,
                logOperation: logOperation,
                logger: logger
            )
        )
    }

    package func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    @discardableResult
    package func requestPermission() -> Bool {
        let requestResult = dependencies.permissionProvider.request()
        store.lastRequestPermission = requestResult

        let preflightResult = dependencies.permissionProvider.preflight()
        store.hasScreenCapturePermission = preflightResult
        store.lastPreflightPermission = preflightResult
        return preflightResult
    }

    @discardableResult
    package func refreshPermission() -> Bool {
        let granted = dependencies.permissionProvider.preflight()
        store.hasScreenCapturePermission = granted
        store.lastPreflightPermission = granted
        return granted
    }

    package func currentActiveDisplayTopologySignature() -> ScreenCaptureDisplayTopologySignature {
        dependencies.displayTopologySignatureProvider()
    }

    @discardableResult
    package func clearSnapshotForDeniedPermission(
        loadErrorMessage: String? = nil
    ) async -> ScreenCaptureCatalogRefreshSettlement {
        await coordinator.cancelActiveRefresh()
        applyClearedSnapshot(signature: currentActiveDisplayTopologySignature())
        store.loadErrorMessage = loadErrorMessage
        return recordRefreshSettlement(result: .clearedSnapshot)
    }

    @discardableResult
    package func submitRefresh(
        intent: ScreenCaptureCatalogRefreshIntent
    ) async -> ScreenCaptureCatalogRefreshSettlement {
        let startingSettlementVersion = refreshSettlementVersion
        activeRefreshSubmissionCount += 1
        let result = await executeRefresh(intent: intent)
        let terminalSettlement = result == .superseded
            ? nil
            : recordRefreshSettlement(result: result)
        if result != .superseded {
            precondition(terminalSettlement != nil)
        }
        activeRefreshSubmissionCount -= 1
        resumeRefreshSettlementWaitersIfIdle()

        if let terminalSettlement {
            return terminalSettlement
        }
        if let replacementSettlement = await waitForRefreshSettlement(after: startingSettlementVersion) {
            return replacementSettlement
        }
        return makeRefreshSettlement(id: refreshSettlementVersion, result: .superseded)
    }

    private func executeRefresh(
        intent: ScreenCaptureCatalogRefreshIntent
    ) async -> ScreenCaptureCatalogRefreshResult {
        var staleCommitRetryCount = 0

        while true {
            let permissionGranted = refreshPermission()
            let requestSignature = currentActiveDisplayTopologySignature()
            let request = CatalogRefreshCoordinator.Request(
                intent: intent,
                permissionGranted: permissionGranted,
                currentTopologySignature: requestSignature,
                cachedTopologySignature: store.lastLoadedActiveDisplayTopologySignature,
                hasCachedDisplays: store.displays != nil
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
            case .execute(let loadID):
                store.isLoadingDisplays = true
                store.loadErrorMessage = nil
                store.lastLoadError = nil
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

    package func makeCatalogStateSnapshot() -> ScreenCaptureCatalogStateSnapshot {
        let topologySignature = store.lastLoadedActiveDisplayTopologySignature ?? []
        return ScreenCaptureCatalogStateSnapshot(
            hasScreenCapturePermission: store.hasScreenCapturePermission,
            lastPreflightPermission: store.lastPreflightPermission,
            lastRequestPermission: store.lastRequestPermission,
            isLoadingDisplays: store.isLoadingDisplays,
            hasLoadError: store.loadErrorMessage != nil || store.lastLoadError != nil,
            lastLoadError: store.lastLoadError,
            loadedDisplays: displaySnapshots(store.activeShareableDisplays ?? []),
            topologySignature: topologySignature
        )
    }

    private func recordRefreshSettlement(
        result: ScreenCaptureCatalogRefreshResult
    ) -> ScreenCaptureCatalogRefreshSettlement {
        refreshSettlementVersion &+= 1
        let settlement = makeRefreshSettlement(id: refreshSettlementVersion, result: result)
        lastRefreshSettlement = settlement

        let readyWaiterIDs = refreshSettlementWaiters.compactMap { waiterID, waiter in
            waiter.afterSettlementID < settlement.id ? waiterID : nil
        }
        for waiterID in readyWaiterIDs {
            refreshSettlementWaiters.removeValue(forKey: waiterID)?.continuation.resume(returning: settlement)
        }
        return settlement
    }

    private func waitForRefreshSettlement(
        after settlementID: UInt64
    ) async -> ScreenCaptureCatalogRefreshSettlement? {
        if let lastRefreshSettlement, lastRefreshSettlement.id > settlementID {
            return lastRefreshSettlement
        }
        guard activeRefreshSubmissionCount > 0 else { return nil }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            if let lastRefreshSettlement, lastRefreshSettlement.id > settlementID {
                continuation.resume(returning: lastRefreshSettlement)
                return
            }
            guard activeRefreshSubmissionCount > 0 else {
                continuation.resume(returning: nil)
                return
            }
            refreshSettlementWaiters[waiterID] = RefreshSettlementWaiter(
                afterSettlementID: settlementID,
                continuation: continuation
            )
        }
    }

    private func resumeRefreshSettlementWaitersIfIdle() {
        guard activeRefreshSubmissionCount == 0 else { return }
        let waiters = refreshSettlementWaiters.values
        refreshSettlementWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func makeRefreshSettlement(
        id: UInt64,
        result: ScreenCaptureCatalogRefreshResult
    ) -> ScreenCaptureCatalogRefreshSettlement {
        ScreenCaptureCatalogRefreshSettlement(
            id: id,
            result: result,
            catalog: makeCatalogStateSnapshot()
        )
    }

    private func displaySnapshots(
        _ displays: [SCDisplay]
    ) -> [ScreenCaptureCatalogDisplaySnapshot] {
        displays.map {
            ScreenCaptureCatalogDisplaySnapshot(
                displayID: $0.displayID,
                pixelWidth: $0.width,
                pixelHeight: $0.height
            )
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
            self.dependencies.logger.error(
                "\(self.dependencies.logOperation, privacy: .public) failed: \(String(describing: error), privacy: .public)"
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
            return .completed(.superseded)
        }
    }
}
package actor CatalogRefreshCoordinator {
    package struct Request: Sendable {
        let intent: ScreenCaptureCatalogRefreshIntent
        let permissionGranted: Bool
        let currentTopologySignature: ScreenCaptureDisplayTopologySignature
        let cachedTopologySignature: ScreenCaptureDisplayTopologySignature?
        let hasCachedDisplays: Bool
    }
    package enum PrepareResult: Sendable, Equatable {
        case execute(loadID: UInt64)
        case awaitInFlight(loadID: UInt64)
        case reusedSnapshot
        case clearedSnapshot
        case failed
    }
    package enum ExecutionResult: Sendable {
        case reloadedSnapshot([SendableDisplay])
        case failed(error: any Error, shouldClearDisplays: Bool)
        case clearedSnapshot
        case failedSuperseded
    }

    private let loadShareableDisplays: @Sendable () async throws -> [SendableDisplay]
    private var nextLoadID: UInt64 = 0
    private var activeLoadID: UInt64?
    private var activeTask: Task<[SendableDisplay], Error>?
    private var resolutionsByLoadID: [UInt64: ExecutionResult] = [:]
    private var resolutionWaitersByLoadID: [UInt64: [CheckedContinuation<ExecutionResult, Never>]] = [:]

    package init(
        loadShareableDisplays: @escaping @Sendable () async throws -> [SendableDisplay]
    ) {
        self.loadShareableDisplays = loadShareableDisplays
    }

    package func prepare(request: Request) -> PrepareResult {
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
                return .awaitInFlight(loadID: activeLoadID)
            }
            return .reusedSnapshot
        }

        cancelActiveRefresh()
        nextLoadID &+= 1
        let loadID = nextLoadID
        activeLoadID = loadID
        startLoad(loadID: loadID)
        return .execute(loadID: loadID)
    }

    package func executeLoad(loadID: UInt64) async -> ExecutionResult {
        if let resolution = resolutionsByLoadID[loadID] {
            return resolution
        }
        guard activeLoadID == loadID else {
            return .failedSuperseded
        }
        return await withCheckedContinuation { continuation in
            if let resolution = resolutionsByLoadID[loadID] {
                continuation.resume(returning: resolution)
                return
            }
            guard activeLoadID == loadID else {
                continuation.resume(returning: .failedSuperseded)
                return
            }
            resolutionWaitersByLoadID[loadID, default: []].append(continuation)
        }
    }

    package func cancelActiveRefresh() {
        guard let activeLoadID else { return }
        activeTask?.cancel()
        activeTask = nil
        self.activeLoadID = nil
        resolve(loadID: activeLoadID, with: .failedSuperseded)
    }

    private func startLoad(loadID: UInt64) {
        let task = Task<[SendableDisplay], Error> { [loadShareableDisplays] in
            return try await loadShareableDisplays()
        }
        activeTask = task
        Task {
            let resolution: ExecutionResult
            do {
                resolution = .reloadedSnapshot(try await task.value)
            } catch is CancellationError {
                resolution = .failedSuperseded
            } catch {
                resolution = .failed(error: error, shouldClearDisplays: false)
            }
            completeLoad(loadID: loadID, resolution: resolution)
        }
    }

    private func completeLoad(loadID: UInt64, resolution: ExecutionResult) {
        guard resolutionsByLoadID[loadID] == nil else { return }
        if activeLoadID == loadID {
            activeTask = nil
            activeLoadID = nil
        }
        resolve(loadID: loadID, with: resolution)
    }

    private func resolve(loadID: UInt64, with resolution: ExecutionResult) {
        resolutionsByLoadID[loadID] = resolution
        let waiters = resolutionWaitersByLoadID.removeValue(forKey: loadID) ?? []
        for waiter in waiters {
            waiter.resume(returning: resolution)
        }
        let oldestRetainedLoadID = nextLoadID > 32 ? nextLoadID - 32 : 0
        resolutionsByLoadID = resolutionsByLoadID.filter { $0.key >= oldestRetainedLoadID }
    }
}
