import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class DisplayTopologyRefreshLifecycleController {
    typealias DisplayTopologySignatureProvider = @MainActor () -> ScreenCaptureDisplayTopologySignature
    typealias SleepOperation = @Sendable (Duration) async -> Void

    private(set) var showToolbarRefresh = false

    @ObservationIgnored private let displayRefreshMonitor: any DisplayReconfigurationMonitoring
    @ObservationIgnored private let displayTopologySignatureProvider: DisplayTopologySignatureProvider
    @ObservationIgnored private let sleep: SleepOperation
    @ObservationIgnored private let fallbackPollingInterval: Duration
    @ObservationIgnored private let recoveryAttemptInterval: Int
    @ObservationIgnored private var displayRefreshFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownDisplayTopologySignature: ScreenCaptureDisplayTopologySignature = []

    init(
        displayRefreshMonitor: any DisplayReconfigurationMonitoring = DebouncingDisplayReconfigurationMonitor(),
        displayTopologySignatureProvider: @escaping DisplayTopologySignatureProvider = {
            ScreenCaptureDisplayTopologySignatureResolver.current(
                activeDisplayIDsProvider: {
                    Set(NSScreen.screens.compactMap(\.cgDirectDisplayID))
                }
            )
        },
        sleep: @escaping SleepOperation = { duration in
            try? await Task.sleep(for: duration)
        },
        fallbackPollingInterval: Duration = .seconds(1),
        recoveryAttemptInterval: Int = 5
    ) {
        self.displayRefreshMonitor = displayRefreshMonitor
        self.displayTopologySignatureProvider = displayTopologySignatureProvider
        self.sleep = sleep
        self.fallbackPollingInterval = fallbackPollingInterval
        self.recoveryAttemptInterval = max(1, recoveryAttemptInterval)
    }

    func handleAppear(onTopologyChanged: @escaping @MainActor () -> Void) {
        startDisplayRefreshMonitoring(onTopologyChanged: onTopologyChanged)
    }

    func handleDisappear() {
        stopDisplayRefreshMonitoring()
    }

    private func startDisplayRefreshMonitoring(onTopologyChanged: @escaping @MainActor () -> Void) {
        lastKnownDisplayTopologySignature = displayTopologySignatureProvider()
        let registered = displayRefreshMonitor.start {
            onTopologyChanged()
        }
        showToolbarRefresh = !registered
        if registered {
            stopDisplayRefreshFallbackPolling()
            return
        }

        AppLog.sharing.error(
            "Display reconfiguration callback registration failed; enabling polling fallback."
        )
        startDisplayRefreshFallbackPolling(onTopologyChanged: onTopologyChanged)
    }

    private func stopDisplayRefreshMonitoring() {
        displayRefreshMonitor.stop()
        stopDisplayRefreshFallbackPolling()
    }

    private func startDisplayRefreshFallbackPolling(onTopologyChanged: @escaping @MainActor () -> Void) {
        guard displayRefreshFallbackTask == nil else { return }
        lastKnownDisplayTopologySignature = displayTopologySignatureProvider()
        displayRefreshFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var cycle = 0
            while !Task.isCancelled {
                await self.sleep(self.fallbackPollingInterval)
                guard !Task.isCancelled else { break }

                self.refreshDisplaysIfTopologyChanged(onTopologyChanged: onTopologyChanged)
                cycle += 1
                if cycle % self.recoveryAttemptInterval != 0 { continue }

                let recovered = self.displayRefreshMonitor.start {
                    onTopologyChanged()
                }
                if recovered {
                    self.showToolbarRefresh = false
                    AppLog.sharing.notice(
                        "Display reconfiguration callback recovered; disabling polling fallback."
                    )
                    self.stopDisplayRefreshFallbackPolling()
                    break
                }
            }
        }
    }

    private func refreshDisplaysIfTopologyChanged(onTopologyChanged: @escaping @MainActor () -> Void) {
        let signature = displayTopologySignatureProvider()
        guard signature != lastKnownDisplayTopologySignature else { return }
        lastKnownDisplayTopologySignature = signature
        onTopologyChanged()
    }

    private func stopDisplayRefreshFallbackPolling() {
        displayRefreshFallbackTask?.cancel()
        displayRefreshFallbackTask = nil
    }
}
