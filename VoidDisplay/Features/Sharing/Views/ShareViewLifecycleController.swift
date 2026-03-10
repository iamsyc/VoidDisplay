import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ShareViewLifecycleController {
    typealias DisplayTopologySignatureProvider = @MainActor () -> [CGDirectDisplayID]
    typealias SleepOperation = @Sendable (Duration) async -> Void

    private(set) var showToolbarRefresh = false

    @ObservationIgnored private let displayRefreshMonitor: any DisplayReconfigurationMonitoring
    @ObservationIgnored private let displayTopologySignatureProvider: DisplayTopologySignatureProvider
    @ObservationIgnored private let sleep: SleepOperation
    @ObservationIgnored private let fallbackPollingInterval: Duration
    @ObservationIgnored private let recoveryAttemptInterval: Int
    @ObservationIgnored private var displayRefreshFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownDisplayTopologySignature: [CGDirectDisplayID] = []

    init(
        displayRefreshMonitor: any DisplayReconfigurationMonitoring = DebouncingDisplayReconfigurationMonitor(),
        displayTopologySignatureProvider: @escaping DisplayTopologySignatureProvider = {
            NSScreen.screens.compactMap(\.cgDirectDisplayID).sorted()
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

    func handleAppear(viewModel: ShareViewModel) {
        viewModel.refreshPermissionAndMaybeLoad()
        startDisplayRefreshMonitoring(viewModel: viewModel)
    }

    func handleDisappear(viewModel: ShareViewModel) {
        viewModel.cancelInFlightDisplayLoad()
        stopDisplayRefreshMonitoring()
    }

    private func startDisplayRefreshMonitoring(viewModel: ShareViewModel) {
        lastKnownDisplayTopologySignature = displayTopologySignatureProvider()
        let registered = displayRefreshMonitor.start {
            guard viewModel.catalog.hasScreenCapturePermission == true else { return }
            viewModel.refreshDisplaysBackgroundSafe()
        }
        showToolbarRefresh = !registered
        if registered {
            stopDisplayRefreshFallbackPolling()
            return
        }

        AppLog.sharing.error(
            "Display reconfiguration callback registration failed in sharing view; enabling polling fallback."
        )
        startDisplayRefreshFallbackPolling(viewModel: viewModel)
    }

    private func stopDisplayRefreshMonitoring() {
        displayRefreshMonitor.stop()
        stopDisplayRefreshFallbackPolling()
    }

    private func startDisplayRefreshFallbackPolling(viewModel: ShareViewModel) {
        guard displayRefreshFallbackTask == nil else { return }
        lastKnownDisplayTopologySignature = displayTopologySignatureProvider()
        displayRefreshFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var cycle = 0
            while !Task.isCancelled {
                await self.sleep(self.fallbackPollingInterval)
                guard !Task.isCancelled else { break }
                guard viewModel.catalog.hasScreenCapturePermission == true else { continue }

                self.refreshDisplaysIfTopologyChanged(viewModel: viewModel)
                cycle += 1
                if cycle % self.recoveryAttemptInterval != 0 { continue }

                let recovered = self.displayRefreshMonitor.start {
                    guard viewModel.catalog.hasScreenCapturePermission == true else { return }
                    viewModel.refreshDisplaysBackgroundSafe()
                }
                if recovered {
                    self.showToolbarRefresh = false
                    AppLog.sharing.notice(
                        "Display reconfiguration callback recovered in sharing view; disabling polling fallback."
                    )
                    self.stopDisplayRefreshFallbackPolling()
                    break
                }
            }
        }
    }

    private func refreshDisplaysIfTopologyChanged(viewModel: ShareViewModel) {
        let signature = displayTopologySignatureProvider()
        guard signature != lastKnownDisplayTopologySignature else { return }
        lastKnownDisplayTopologySignature = signature
        viewModel.refreshDisplaysBackgroundSafe()
    }

    private func stopDisplayRefreshFallbackPolling() {
        displayRefreshFallbackTask?.cancel()
        displayRefreshFallbackTask = nil
    }
}
