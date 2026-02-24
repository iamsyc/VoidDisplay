import Foundation
import OSLog

@MainActor
struct TeardownSettlement {
    let terminationObserved: Bool
    let offlineConfirmed: Bool
}

@MainActor
final class DisplayTeardownCoordinator {
    private struct TerminationWaiter {
        let expectedGeneration: UInt64
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private struct OfflineWaiter {
        let serialNum: UInt32
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    private enum TeardownSettlementEvent {
        case termination(Bool)
        case offline(Bool)
    }

    private var terminationWaitersByConfigId: [UUID: TerminationWaiter] = [:]
    private var offlineWaitersByToken: [UUID: OfflineWaiter] = [:]
    private let managedDisplayOnlineChecker: (UInt32) -> Bool
    private var isReconfigurationMonitorAvailable: Bool
    private var didLogOfflinePollingFallback = false
    private var runtimeGenerationProvider: ((UUID) -> UInt64?)?

    init(
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        isReconfigurationMonitorAvailable: Bool
    ) {
        self.managedDisplayOnlineChecker = managedDisplayOnlineChecker
        self.isReconfigurationMonitorAvailable = isReconfigurationMonitorAvailable
    }

    func setRuntimeGenerationProvider(_ provider: @escaping (UUID) -> UInt64?) {
        runtimeGenerationProvider = provider
    }

    func setReconfigurationMonitorAvailable(_ isAvailable: Bool) {
        isReconfigurationMonitorAvailable = isAvailable
    }

    func waitForManagedDisplayOffline(
        serialNum: UInt32,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        if !isManagedDisplayOnline(serialNum: serialNum) {
            return true
        }

        if !isReconfigurationMonitorAvailable {
            if !didLogOfflinePollingFallback {
                AppLog.virtualDisplay.warning(
                    "Display reconfiguration callback unavailable; waiting for offline state via polling fallback."
                )
                didLogOfflinePollingFallback = true
            }
            return await waitForManagedDisplayOfflineByPolling(
                serialNum: serialNum,
                timeout: timeout
            )
        }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.completeOfflineWaiterAfterTimeout(token: token)
                }

                offlineWaitersByToken[token] = OfflineWaiter(
                    serialNum: serialNum,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                completeOfflineWaitersIfPossible()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelOfflineWaiter(token: token)
            }
        }
    }

    func waitForManagedDisplaysOffline(
        serialNumbers: [UInt32],
        timeout: TimeInterval
    ) async -> Bool {
        for serial in Set(serialNumbers).sorted() {
            let offline = await waitForManagedDisplayOffline(
                serialNum: serial,
                timeout: timeout
            )
            if !offline {
                return false
            }
        }
        return true
    }

    func waitForTeardownSettlement(
        configId: UUID,
        expectedGeneration: UInt64,
        serialNum: UInt32,
        terminationTimeout: TimeInterval,
        offlineTimeout: TimeInterval
    ) async -> TeardownSettlement {
        await withTaskGroup(of: TeardownSettlementEvent.self, returning: TeardownSettlement.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .termination(false) }
                return .termination(
                    await self.waitForTermination(
                        configId: configId,
                        expectedGeneration: expectedGeneration,
                        timeout: terminationTimeout
                    )
                )
            }
            group.addTask { [weak self] in
                guard let self else { return .offline(false) }
                return .offline(
                    await self.waitForManagedDisplayOffline(
                        serialNum: serialNum,
                        timeout: offlineTimeout
                    )
                )
            }

            var terminationObserved: Bool?
            var offlineConfirmed: Bool?

            while let event = await group.next() {
                switch event {
                case .termination(let observed):
                    terminationObserved = observed
                    if observed {
                        group.cancelAll()
                        return TeardownSettlement(
                            terminationObserved: true,
                            offlineConfirmed: true
                        )
                    }

                case .offline(let confirmed):
                    offlineConfirmed = confirmed
                    if confirmed {
                        group.cancelAll()
                        return TeardownSettlement(
                            terminationObserved: terminationObserved ?? false,
                            offlineConfirmed: true
                        )
                    }
                }

                if let terminationObserved, let offlineConfirmed {
                    return TeardownSettlement(
                        terminationObserved: terminationObserved,
                        offlineConfirmed: offlineConfirmed
                    )
                }
            }

            return TeardownSettlement(
                terminationObserved: terminationObserved ?? false,
                offlineConfirmed: offlineConfirmed ?? false
            )
        }
    }

    func settleRebuildTeardown(
        configId: UUID,
        serialNum: UInt32,
        generationToWaitFor: UInt64?,
        rebuildTerminationTimeout: TimeInterval,
        rebuildOfflineTimeout: TimeInterval,
        rebuildFinalOfflineConfirmationTimeout: TimeInterval
    ) async throws -> Bool {
        var terminationConfirmed = true
        if let generationToWaitFor {
            let settlement = await waitForTeardownSettlement(
                configId: configId,
                expectedGeneration: generationToWaitFor,
                serialNum: serialNum,
                terminationTimeout: rebuildTerminationTimeout,
                offlineTimeout: rebuildOfflineTimeout
            )
            if !settlement.terminationObserved {
                AppLog.virtualDisplay.debug(
                    "Virtual display teardown termination callback not observed before timeout (config: \(configId.uuidString, privacy: .public), generation: \(generationToWaitFor, privacy: .public)). Continue rebuild with extended retries after offline confirmation."
                )
            }
            if !settlement.offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Rebuild aborted because previous display with same serial is still online after teardown settlement (serial: \(serialNum, privacy: .public), generation: \(generationToWaitFor, privacy: .public), config: \(configId.uuidString, privacy: .public))."
                )
                throw VirtualDisplayService.VirtualDisplayError.teardownTimedOut
            }
            terminationConfirmed = settlement.terminationObserved
        }

        let finalOfflineConfirmed = await waitForManagedDisplayOffline(
            serialNum: serialNum,
            timeout: rebuildFinalOfflineConfirmationTimeout
        )
        if !finalOfflineConfirmed {
            AppLog.virtualDisplay.error(
                "Rebuild aborted because previous display with same serial is still online during final offline confirmation (serial: \(serialNum, privacy: .public), config: \(configId.uuidString, privacy: .public))."
            )
            throw VirtualDisplayService.VirtualDisplayError.teardownTimedOut
        }
        return terminationConfirmed
    }

    func observeTermination(configId: UUID, generation: UInt64) {
        AppLog.virtualDisplay.debug(
            "Observe termination event (config: \(configId.uuidString, privacy: .public), generation: \(generation, privacy: .public))."
        )
        completeTerminationWaiter(configId: configId, expectedGeneration: generation, result: true)
    }

    func cancelTerminationWaiter(configId: UUID) {
        guard let waiter = terminationWaitersByConfigId.removeValue(forKey: configId) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: false)
    }

    func cancelAllTerminationWaiters() {
        let keys = terminationWaitersByConfigId.keys
        for key in keys {
            cancelTerminationWaiter(configId: key)
        }
    }

    func completeOfflineWaitersIfPossible() {
        let tokens = offlineWaitersByToken.keys
        for token in tokens {
            guard let waiter = offlineWaitersByToken[token] else { continue }
            if !isManagedDisplayOnline(serialNum: waiter.serialNum) {
                completeOfflineWaiter(token: token, result: true)
            }
        }
    }

    func cancelAllOfflineWaiters() {
        let tokens = offlineWaitersByToken.keys
        for token in tokens {
            completeOfflineWaiter(token: token, result: false)
        }
    }

    func isManagedDisplayOnline(serialNum: UInt32) -> Bool {
        managedDisplayOnlineChecker(serialNum)
    }

    private func waitForTermination(
        configId: UUID,
        expectedGeneration: UInt64,
        timeout: TimeInterval
    ) async -> Bool {
        if !isAwaitedGenerationCurrent(configId: configId, expectedGeneration: expectedGeneration) {
            AppLog.virtualDisplay.debug(
                "Skip termination wait because expected generation is no longer current (config: \(configId.uuidString, privacy: .public), expectedGeneration: \(expectedGeneration, privacy: .public))."
            )
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !isAwaitedGenerationCurrent(configId: configId, expectedGeneration: expectedGeneration) {
                    AppLog.virtualDisplay.debug(
                        "Skip termination wait during continuation setup because expected generation is no longer current (config: \(configId.uuidString, privacy: .public), expectedGeneration: \(expectedGeneration, privacy: .public))."
                    )
                    continuation.resume(returning: true)
                    return
                }

                cancelTerminationWaiter(configId: configId)
                AppLog.virtualDisplay.debug(
                    "Register termination waiter (config: \(configId.uuidString, privacy: .public), expectedGeneration: \(expectedGeneration, privacy: .public), timeoutSec: \(timeout, privacy: .public))."
                )

                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    AppLog.virtualDisplay.debug(
                        "Termination waiter timed out (config: \(configId.uuidString, privacy: .public), expectedGeneration: \(expectedGeneration, privacy: .public))."
                    )
                    self?.completeTerminationWaiter(
                        configId: configId,
                        expectedGeneration: expectedGeneration,
                        result: false
                    )
                }

                terminationWaitersByConfigId[configId] = TerminationWaiter(
                    expectedGeneration: expectedGeneration,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelTerminationWaiter(
                    configId: configId,
                    expectedGeneration: expectedGeneration
                )
            }
        }
    }

    private func isAwaitedGenerationCurrent(
        configId: UUID,
        expectedGeneration: UInt64
    ) -> Bool {
        guard let runtimeGenerationProvider else {
            return true
        }
        return runtimeGenerationProvider(configId) == expectedGeneration
    }

    private func cancelTerminationWaiter(configId: UUID, expectedGeneration: UInt64) {
        guard let waiter = terminationWaitersByConfigId[configId] else { return }
        guard waiter.expectedGeneration == expectedGeneration else { return }
        cancelTerminationWaiter(configId: configId)
    }

    private func completeTerminationWaiter(configId: UUID, expectedGeneration: UInt64, result: Bool) {
        guard let waiter = terminationWaitersByConfigId[configId] else { return }
        guard waiter.expectedGeneration == expectedGeneration else { return }
        terminationWaitersByConfigId[configId] = nil
        waiter.timeoutTask.cancel()
        AppLog.virtualDisplay.debug(
            "Complete termination waiter (config: \(configId.uuidString, privacy: .public), expectedGeneration: \(expectedGeneration, privacy: .public), result: \(result, privacy: .public))."
        )
        waiter.continuation.resume(returning: result)
    }

    private func waitForManagedDisplayOfflineByPolling(
        serialNum: UInt32,
        timeout: TimeInterval,
        interval: TimeInterval = 0.1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }
            if !isManagedDisplayOnline(serialNum: serialNum) {
                return true
            }
            await sleepForRetry(seconds: interval)
        }
        return !isManagedDisplayOnline(serialNum: serialNum)
    }

    private func completeOfflineWaiter(token: UUID, result: Bool) {
        guard let waiter = offlineWaitersByToken.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    private func completeOfflineWaiterAfterTimeout(token: UUID) {
        guard let waiter = offlineWaitersByToken[token] else { return }
        let isOffline = !isManagedDisplayOnline(serialNum: waiter.serialNum)
        completeOfflineWaiter(token: token, result: isOffline)
    }

    private func cancelOfflineWaiter(token: UUID) {
        completeOfflineWaiter(token: token, result: false)
    }

    private func sleepForRetry(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // Ignore cancellation and let retry loop exit on next check.
        }
    }
}
