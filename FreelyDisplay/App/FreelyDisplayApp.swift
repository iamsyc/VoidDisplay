//
//  FreelyDisplayApp.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import ScreenCaptureKit
import CoreGraphics
import Observation

@main
struct FreelyDisplayApp: App {
    @State private var appHelper = AppHelper()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(appHelper)
        }

        WindowGroup(for: UUID.self) { $sessionId in
            CaptureDisplayWindowRoot(sessionId: sessionId)
                .environment(appHelper)
        }

        Settings {
            AppSettingsView()
                .environment(appHelper)
        }
    }
}

private struct CaptureDisplayWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID?

    var body: some View {
        if let sessionId {
            CaptureDisplayView(sessionId: sessionId)
                .navigationTitle("Screen Monitoring")
        } else {
            Color.clear
                .onAppear { dismiss() }
        }
    }
}

@MainActor
@Observable
final class AppHelper {
    private static let uiTestModeEnvironmentKey = "FREELYDISPLAY_UI_TEST_MODE"

    struct ScreenMonitoringSession: Identifiable {
        let id: UUID
        let displayID: CGDirectDisplayID
        let displayName: String
        let resolutionText: String
        let isVirtualDisplay: Bool
        let stream: SCStream
        let delegate: StreamDelegate
    }

    var displays: [CGVirtualDisplay] = []
    var displayConfigs: [VirtualDisplayConfig] = []  // Stored configs (persisted)
    private(set) var runningConfigIds: Set<UUID> = []
    private(set) var restoreFailures: [VirtualDisplayRestoreFailure] = []
    var screenCaptureSessions: [ScreenMonitoringSession] = []
    var sharingScreenCaptureObject: SCStream? = nil
    var sharingScreenCaptureStream: Capture? = nil
    var isSharing = false
    var isWebServiceRunning = false

    @ObservationIgnored private(set) var webServer: WebServer? = nil
    @ObservationIgnored var sharingScreenCaptureDelegate: StreamDelegate? = nil

    @ObservationIgnored private let captureMonitoringService = CaptureMonitoringService()
    @ObservationIgnored private let sharingService = SharingService()
    @ObservationIgnored private let virtualDisplayService = VirtualDisplayService()

    typealias VirtualDisplayError = VirtualDisplayService.VirtualDisplayError

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment[Self.uiTestModeEnvironmentKey] == "1"
    }

    init(preview: Bool = false) {
        guard !preview, !isUITestMode else { return }

        _ = startWebService()
        virtualDisplayService.loadPersistedConfigs()
        virtualDisplayService.restoreDesiredVirtualDisplays()
        syncVirtualDisplayState()
    }

    @discardableResult
    func startWebService() -> Bool {
        let started = sharingService.startWebService()
        syncSharingState()
        return started
    }

    func stopWebService() {
        sharingService.stopWebService()
        syncSharingState()
    }

    func beginSharing(stream: SCStream, output: Capture, delegate: StreamDelegate) {
        sharingService.beginSharing(stream: stream, output: output, delegate: delegate)
        syncSharingState()
    }

    func stopSharing() {
        sharingService.stopSharing()
        syncSharingState()
    }

    var webServicePortValue: UInt16 {
        sharingService.webServicePortValue
    }

    private func syncSharingState() {
        sharingScreenCaptureObject = sharingService.currentStream
        sharingScreenCaptureStream = sharingService.currentCapture
        sharingScreenCaptureDelegate = sharingService.currentDelegate
        webServer = sharingService.currentWebServer
        isSharing = sharingService.isSharing
        isWebServiceRunning = sharingService.isWebServiceRunning
    }

    // MARK: - Screen Monitoring

    func monitoringSession(for id: UUID) -> ScreenMonitoringSession? {
        captureMonitoringService.monitoringSession(for: id)
    }

    func addMonitoringSession(_ session: ScreenMonitoringSession) {
        captureMonitoringService.addMonitoringSession(session)
        syncCaptureMonitoringState()
    }

    func removeMonitoringSession(id: UUID) {
        captureMonitoringService.removeMonitoringSession(id: id)
        syncCaptureMonitoringState()
    }

    private func syncCaptureMonitoringState() {
        screenCaptureSessions = captureMonitoringService.currentSessions
    }

    private func syncVirtualDisplayState() {
        displays = virtualDisplayService.currentDisplays
        displayConfigs = virtualDisplayService.currentDisplayConfigs
        runningConfigIds = virtualDisplayService.currentRunningConfigIds
        restoreFailures = virtualDisplayService.currentRestoreFailures
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        virtualDisplayService.runtimeDisplay(for: configId)
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        virtualDisplayService.isVirtualDisplayRunning(configId: configId)
    }

    func clearRestoreFailures() {
        virtualDisplayService.clearRestoreFailures()
        syncVirtualDisplayState()
    }

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay {
        let display = try virtualDisplayService.createDisplay(
            name: name,
            serialNum: serialNum,
            physicalSize: physicalSize,
            maxPixels: maxPixels,
            modes: modes
        )
        syncVirtualDisplayState()
        return display
    }

    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        let display = try virtualDisplayService.createDisplayFromConfig(config)
        syncVirtualDisplayState()
        return display
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        virtualDisplayService.disableDisplay(display, modes: modes)
        syncVirtualDisplayState()
    }

    func disableDisplayByConfig(_ configId: UUID) {
        virtualDisplayService.disableDisplayByConfig(configId)
        syncVirtualDisplayState()
    }

    func enableDisplay(_ configId: UUID) throws {
        try virtualDisplayService.enableDisplay(configId)
        syncVirtualDisplayState()
    }

    func destroyDisplay(_ configId: UUID) {
        virtualDisplayService.destroyDisplay(configId)
        syncVirtualDisplayState()
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {
        virtualDisplayService.destroyDisplay(display)
        syncVirtualDisplayState()
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        virtualDisplayService.getConfig(configId)
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        virtualDisplayService.updateConfig(updated)
        syncVirtualDisplayState()
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        virtualDisplayService.applyModes(configId: configId, modes: modes)
        syncVirtualDisplayState()
    }

    func rebuildVirtualDisplay(configId: UUID) throws {
        // Release AppHelper-side references first so the old runtime display can fully tear down.
        displays.removeAll()
        defer { syncVirtualDisplayState() }
        try virtualDisplayService.rebuildVirtualDisplay(configId: configId)
    }

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        virtualDisplayService.getConfig(for: display)
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        virtualDisplayService.updateConfig(for: display, modes: modes)
        syncVirtualDisplayState()
    }

    func nextAvailableSerialNumber() -> UInt32 {
        virtualDisplayService.nextAvailableSerialNumber()
    }

    @discardableResult
    func resetVirtualDisplayData() -> Int {
        let removed = virtualDisplayService.resetAllVirtualDisplayData()
        syncVirtualDisplayState()
        return removed
    }
}

private struct AppSettingsView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var showResetConfirmation = false
    @State private var resetCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Virtual Display")
                .font(.headline)

            Text("Reset will remove all saved virtual display configurations and stop currently managed virtual displays.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Reset Virtual Display Configurations", role: .destructive) {
                showResetConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            if resetCompleted {
                Text("Reset completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .frame(width: 420, height: 170, alignment: .topLeading)
        .confirmationDialog(
            "Reset Virtual Display Configurations?",
            isPresented: $showResetConfirmation
        ) {
            Button("Reset", role: .destructive) {
                _ = appHelper.resetVirtualDisplayData()
                resetCompleted = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}
