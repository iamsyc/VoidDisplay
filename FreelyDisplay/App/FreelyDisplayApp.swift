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
    private static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

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
    var activeSharingDisplayIDs: Set<CGDirectDisplayID> = []
    var sharingClientCount = 0
    var sharingClientCounts: [CGDirectDisplayID: Int] = [:]
    var isSharing = false
    var isWebServiceRunning = false

    @ObservationIgnored private(set) var webServer: WebServer? = nil

    @ObservationIgnored private let captureMonitoringService = CaptureMonitoringService()
    @ObservationIgnored private let sharingService = SharingService()
    @ObservationIgnored private let virtualDisplayService = VirtualDisplayService()

    typealias VirtualDisplayError = VirtualDisplayService.VirtualDisplayError

    enum SharePageURLFailure: Error, Equatable {
        case serviceNotRunning
        case lanUnavailable
        case displayUnavailable
    }

    private var isUITestMode: Bool {
        UITestRuntime.isEnabled
    }

    private var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment[Self.xCTestConfigurationEnvironmentKey] != nil
    }

    init(preview: Bool = false) {
        guard !preview else { return }

        if isUITestMode {
            applyUITestFixture()
            return
        }

        guard !isRunningUnderXCTest else { return }

        _ = startWebService()
        virtualDisplayService.loadPersistedConfigs()
        virtualDisplayService.restoreDesiredVirtualDisplays()
        syncVirtualDisplayState()
    }

    private func applyUITestFixture() {
        let fixtureConfigs = Self.uiTestVirtualDisplayConfigs()

        displayConfigs = fixtureConfigs
        runningConfigIds = Set(fixtureConfigs.prefix(1).map(\.id))
        displays = []
        restoreFailures = []
        screenCaptureSessions = []
        activeSharingDisplayIDs = []
        sharingClientCount = 0
        isSharing = false
        isWebServiceRunning = false
        webServer = nil

        switch UITestRuntime.scenario {
        case .baseline:
            break
        case .permissionDenied:
            break
        }
    }

    private static func uiTestVirtualDisplayConfigs() -> [VirtualDisplayConfig] {
        [
            VirtualDisplayConfig(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000013") ?? UUID(),
                name: "虚拟显示器 13 寸",
                serialNum: 1,
                physicalWidth: 286,
                physicalHeight: 179,
                modes: [
                    .init(width: 1440, height: 900, refreshRate: 60, enableHiDPI: false)
                ],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000014") ?? UUID(),
                name: "虚拟显示器 14 寸",
                serialNum: 2,
                physicalWidth: 309,
                physicalHeight: 174,
                modes: [
                    .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
                ],
                desiredEnabled: true
            )
        ]
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

    func registerShareableDisplays(_ displays: [SCDisplay]) {
        sharingService.registerShareableDisplays(
            displays
        ) { [weak self] displayID in
            self?.virtualSerialForManagedDisplay(displayID)
        }
        syncSharingState()
    }

    func beginSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        output: Capture,
        delegate: StreamDelegate
    ) {
        sharingService.startSharing(
            displayID: displayID,
            stream: stream,
            output: output,
            delegate: delegate
        )
        syncSharingState()
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        sharingService.stopSharing(displayID: displayID)
        syncSharingState()
    }

    func stopAllSharing() {
        sharingService.stopAllSharing()
        syncSharingState()
    }

    var webServicePortValue: UInt16 {
        sharingService.webServicePortValue
    }

    private func syncSharingState() {
        webServer = sharingService.currentWebServer
        sharingClientCount = sharingService.activeStreamClientCount
        activeSharingDisplayIDs = sharingService.activeSharingDisplayIDs
        isSharing = sharingService.hasAnyActiveSharing
        isWebServiceRunning = sharingService.isWebServiceRunning
        refreshSharingClientCounts()
    }

    func refreshSharingClientCount() {
        sharingClientCount = sharingService.activeStreamClientCount
        refreshSharingClientCounts()
    }

    private func refreshSharingClientCounts() {
        guard isWebServiceRunning else {
            sharingClientCounts = [:]
            return
        }
        var counts: [CGDirectDisplayID: Int] = [:]
        for displayID in sharingService.activeSharingDisplayIDs {
            if let target = sharingService.shareTarget(for: displayID) {
                counts[displayID] = sharingService.streamClientCount(for: target)
            }
        }
        sharingClientCounts = counts
    }

    func isManagedVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        displays.contains(where: { $0.displayID == displayID })
    }

    func isDisplaySharing(displayID: CGDirectDisplayID) -> Bool {
        activeSharingDisplayIDs.contains(displayID)
    }

    func sharePagePath(for displayID: CGDirectDisplayID) -> String? {
        guard let shareID = sharingService.shareID(for: displayID) else { return nil }
        return ShareTarget.id(shareID).displayPath
    }

    func sharePageURLResolution(for displayID: CGDirectDisplayID?) -> Result<URL, SharePageURLFailure> {
        guard isWebServiceRunning else { return .failure(.serviceNotRunning) }
        guard let ip = getLANIPv4Address() else { return .failure(.lanUnavailable) }

        let resolvedDisplayID = displayID ?? CGMainDisplayID()
        guard let path = sharePagePath(for: resolvedDisplayID) else {
            return .failure(.displayUnavailable)
        }

        guard let url = URL(string: "http://\(ip):\(webServicePortValue)\(path)") else {
            return .failure(.displayUnavailable)
        }
        return .success(url)
    }

    func sharePageURL(for displayID: CGDirectDisplayID?) -> URL? {
        guard case .success(let url) = sharePageURLResolution(for: displayID) else {
            return nil
        }
        return url
    }

    func sharePageAddress(for displayID: CGDirectDisplayID?) -> String? {
        sharePageURL(for: displayID)?.absoluteString
    }

    private func virtualSerialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32? {
        displays.first(where: { $0.displayID == displayID })?.serialNum
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

    @discardableResult
    func moveDisplayConfig(_ configId: UUID, direction: VirtualDisplayService.ReorderDirection) -> Bool {
        let moved = virtualDisplayService.moveConfig(configId, direction: direction)
        if moved {
            syncVirtualDisplayState()
        }
        return moved
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
            Text("Virtual Displays")
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
