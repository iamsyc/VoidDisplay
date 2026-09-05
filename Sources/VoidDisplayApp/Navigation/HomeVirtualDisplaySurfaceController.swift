import AppKit
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI
import VoidDisplayCapture
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
@Observable
package final class HomeVirtualDisplaySurfaceController {
    @ObservationIgnored private let capture: CaptureController
    @ObservationIgnored private let sharing: SharingController
    @ObservationIgnored private let virtualDisplay: VirtualDisplayController
    @ObservationIgnored private let capturePerformancePreferences: CapturePerformancePreferences
    @ObservationIgnored private let displayRuntime: DisplayRuntime
    @ObservationIgnored private let sharingAdapter: DisplayRuntimeSharingAdapter

    package let viewModel: VirtualDisplayListViewModel
    package var actionAlert: UserFacingAlertState?
    package var sharingPortInput: String
    package var sharingPortErrorMessage: String?

    private var displayDetectionState = HomeDisplayDetectionState()
    private var catalogSurfaceRegistration: DisplayRuntimeCatalogSurfaceRegistration?
    @ObservationIgnored private var catalogRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var transientFeedbackTask: Task<Void, Never>?

    package init(
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        capturePerformancePreferences: CapturePerformancePreferences,
        displayRuntime: DisplayRuntime,
        sharingAdapter: DisplayRuntimeSharingAdapter
    ) {
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.capturePerformancePreferences = capturePerformancePreferences
        self.displayRuntime = displayRuntime
        self.sharingAdapter = sharingAdapter
        viewModel = VirtualDisplayListViewModel(controller: virtualDisplay)
        sharingPortInput = String(sharing.preferredWebServicePort)
    }

    package var presentation: HomeVirtualDisplaySurfacePresentation {
        HomeVirtualDisplayPresentationMapper.makePresentation(
            snapshot: displayRuntime.makeSnapshot(),
            displayConfigs: virtualDisplay.displayConfigs,
            sharePageAddresses: sharePageAddresses
        )
    }

    package var permissionStatus: HomePermissionStatusRenderState {
        HomePermissionStatusRenderState(
            label: permissionLabel,
            systemImage: permissionSystemImage,
            tint: permissionTint,
            isActive: capture.displayCatalogState.hasScreenCapturePermission != nil,
            canOpenSettings: capture.displayCatalogState.hasScreenCapturePermission == false
        )
    }

    package var sharingSettings: HomeSharingSettingsRenderState {
        HomeSharingSettingsRenderState(
            performanceMode: capturePerformancePreferences.mode,
            portInput: sharingPortInput,
            isPortDirty: isSharingPortDirty,
            portErrorMessage: sharingPortErrorMessage,
            isWebServiceRunning: sharing.isWebServiceRunning,
            webServicePortValue: sharing.webServicePortValue
        )
    }

    package var displayDetectionPresentation: HomeDisplayDetectionPresentation {
        let catalog = displayRuntime.makeSnapshot().catalog
        if displayDetectionState.isScanning || catalog.isLoadingDisplays {
            return .scanning
        }
        if catalog.hasLoadError {
            return .failed
        }
        return displayDetectionState.outcome
    }

    package var isCatalogLoading: Bool {
        displayRuntime.makeSnapshot().catalog.isLoadingDisplays
    }

    package var isWebServiceRunning: Bool {
        sharing.isWebServiceRunning
    }

    package var preferredSharingPort: UInt16 {
        sharing.preferredWebServicePort
    }

    package func itemRenderStates(
        for items: [HomeVirtualDisplayItemPresentation]
    ) -> [HomeVirtualDisplayItemRenderState] {
        items.map { item in
            HomeVirtualDisplayItemRenderState(
                item: item,
                isFirst: items.first?.id == item.id,
                isLast: items.last?.id == item.id,
                isToggling: viewModel.isToggling(configId: item.id),
                isRebuilding: virtualDisplay.isRebuilding(configId: item.id),
                hasRecentApplySuccess: virtualDisplay.hasRecentApplySuccess(configId: item.id),
                rebuildFailureMessage: virtualDisplay.rebuildFailureMessage(configId: item.id),
                isPrimary: viewModel.isPrimaryDisplay(configID: item.id),
                canSetAsPrimary: canSetAsPrimary(item),
                needsDisplayDetection: needsDisplayDetection(item),
                isDisplayDetectionScanning: displayDetectionPresentation.isScanning,
                isPreviewActionDisabled: isPreviewActionDisabled(item),
                isPreviewStarting: item.displayID.map(capture.isStarting(displayID:)) ?? false,
                isWebViewActionDisabled: isWebViewActionDisabled(item),
                isWebViewStarting: item.displayID.map(sharing.isStarting(displayID:)) ?? false
            )
        }
    }

    package func handleAppear() {
        viewModel.handleAppear()
        registerCatalogSurfaceIfNeeded()
    }

    package func handleDisappear() {
        rescanTask?.cancel()
        rescanTask = nil
        transientFeedbackTask?.cancel()
        transientFeedbackTask = nil
        displayDetectionState.invalidate()
        unregisterCatalogSurfaceIfNeeded()
    }

    package func handleRestoreFailuresChanged(_ failures: [VirtualDisplayRestoreFailure]) {
        viewModel.handleRestoreFailuresChanged(failures)
    }

    package func handleCatalogLoadingChanged(_ isLoading: Bool) {
        guard isLoading else { return }
        transientFeedbackTask?.cancel()
        transientFeedbackTask = nil
        displayDetectionState.catalogRefreshDidStart()
    }

    package func handleSharingServiceStateChanged(isRunning: Bool) {
        Task {
            await displayRuntime.handleSharingServiceStateChanged(isRunning: isRunning)
        }
    }

    package func handlePreferredSharingPortChanged(from oldValue: UInt16, to newValue: UInt16) {
        if sharingPortInput == String(oldValue) || sharingPortErrorMessage == nil {
            sharingPortInput = String(newValue)
        }
    }

    package func handleCatalogTopologyChanged() {
        Task {
            await displayRuntime.handleCatalogTopologyChanged()
        }
    }

    package func setCapturePerformanceMode(_ mode: CapturePerformanceMode) {
        capturePerformancePreferences.saveMode(mode)
    }

    package func updateSharingPortDraft(_ newValue: String) {
        sharingPortInput = String(newValue.prefix(5))
        sharingPortErrorMessage = nil
    }

    package func applySharingPortDraft() {
        switch SharePortValidationError.parse(sharingPortInput) {
        case .success(let port):
            sharing.savePreferredWebServicePort(port)
            sharingPortInput = String(port)
            sharingPortErrorMessage = nil
        case .failure(let validationError):
            sharingPortErrorMessage = validationError.userMessage
        }
    }

    package func resetConfigStore() {
        do {
            _ = try virtualDisplay.resetVirtualDisplayData()
        } catch {}
    }

    package func rescanDisplays() {
        guard !displayDetectionState.isScanning else { return }
        let operationID = displayDetectionState.begin(
            previousCatalog: displayRuntime.makeSnapshot().catalog
        )

        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            guard let self else { return }
            let refreshOutcome = await displayRuntime.forceRefreshCatalog(source: .capturePage)
            guard !Task.isCancelled else { return }
            displayDetectionState.complete(
                operationID: operationID,
                refreshOutcome: refreshOutcome
            )
            rescanTask = nil
            scheduleTransientDisplayDetectionFeedback()
        }
    }

    package func perform(
        _ action: HomeVirtualDisplayItemAction,
        for item: HomeVirtualDisplayItemPresentation,
        openPreviewWindow: @escaping @MainActor (CapturePreviewID) -> Void,
        openSharePage: @escaping @MainActor (URL) -> Void,
        editConfig: @escaping @MainActor (UUID) -> Void
    ) {
        switch action {
        case .toggle:
            guard let config = virtualDisplay.getConfig(item.id) else { return }
            viewModel.toggleDisplayState(config)
        case .preview:
            if item.isPreviewing {
                stopPreview(item)
            } else {
                startPreview(item, openPreviewWindow: openPreviewWindow)
            }
        case .webView:
            if item.isSharing {
                stopWebView(item)
            } else {
                startWebView(item)
            }
        case .openSharePage:
            guard item.isSharing,
                  let shareAddress = item.shareAddress,
                  let shareURL = URL(string: shareAddress)
            else {
                return
            }
            openSharePage(shareURL)
        case .copyShareAddress:
            copyShareAddress(item)
        case .edit:
            editConfig(item.id)
        case .moveUp:
            performPersistenceAction {
                _ = try virtualDisplay.moveDisplayConfig(item.id, direction: .up)
            }
        case .moveDown:
            performPersistenceAction {
                _ = try virtualDisplay.moveDisplayConfig(item.id, direction: .down)
            }
        case .setPrimary:
            performPersistenceAction {
                _ = try virtualDisplay.setPrimaryVirtualDisplayByReordering(item.id)
            }
        case .retryRebuild:
            virtualDisplay.retryRebuild(configId: item.id)
        case .delete:
            guard let config = virtualDisplay.getConfig(item.id) else { return }
            viewModel.requestDelete(config)
        }
    }

    package func performMenuBarAction(
        _ action: MenuBarVirtualDisplayAction,
        for item: HomeVirtualDisplayItemPresentation,
        openPreviewWindow: @escaping @MainActor (CapturePreviewID) -> Void
    ) {
        switch action {
        case .toggle:
            perform(
                .toggle,
                for: item,
                openPreviewWindow: openPreviewWindow,
                openSharePage: { _ in },
                editConfig: { _ in }
            )
        case .openPreview:
            startPreview(item, openPreviewWindow: openPreviewWindow)
        case .toggleWebView:
            perform(
                .webView,
                for: item,
                openPreviewWindow: openPreviewWindow,
                openSharePage: { _ in },
                editConfig: { _ in }
            )
        case .copyShareAddress:
            copyShareAddress(item)
        }
    }

    package func dismissActionAlert() {
        actionAlert = nil
    }

    private func registerCatalogSurfaceIfNeeded() {
        guard catalogSurfaceRegistration == nil else { return }
        let registration = displayRuntime.registerCatalogSurface(source: .capturePage)
        catalogSurfaceRegistration = registration
        catalogRefreshTask?.cancel()
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            await displayRuntime.refreshCatalogSurface(registration)
            guard !Task.isCancelled else { return }
            if sharing.isWebServiceRunning {
                await displayRuntime.handleSharingServiceStateChanged(isRunning: true)
            }
            catalogRefreshTask = nil
        }
    }

    private func unregisterCatalogSurfaceIfNeeded() {
        guard let registration = catalogSurfaceRegistration else { return }
        catalogSurfaceRegistration = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        Task {
            await displayRuntime.unregisterCatalogSurface(registration)
        }
    }

    private func scheduleTransientDisplayDetectionFeedback() {
        transientFeedbackTask?.cancel()
        let presentation = displayDetectionPresentation
        guard presentation.isTransient else {
            transientFeedbackTask = nil
            return
        }
        transientFeedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard let self else { return }
            displayDetectionState.clearTransientOutcome(matching: presentation)
            transientFeedbackTask = nil
        }
    }

    private func startPreview(
        _ item: HomeVirtualDisplayItemPresentation,
        openPreviewWindow: @escaping @MainActor (CapturePreviewID) -> Void
    ) {
        guard let displayID = item.displayID else { return }
        Task {
            if let existingSession = previewActions.previewIDForDisplayID(displayID) {
                openPreviewWindow(existingSession)
                return
            }
            guard let display = await resolveDisplay(displayID: displayID) else {
                presentActionError(
                    title: String(localized: "Start Preview Failed"),
                    message: String(localized: "Display is not available for preview.")
                )
                return
            }
            do {
                let outcome = try await previewActions.startPreview(
                    display,
                    CapturePreviewDisplayMetadata(
                        displayName: displayName(for: display),
                        resolutionText: resolutionText(for: display),
                        isVirtualDisplay: true
                    )
                )
                if case .started(let previewID) = outcome {
                    openPreviewWindow(previewID)
                }
            } catch is CancellationError {
            } catch {
                presentActionError(
                    title: String(localized: "Start Preview Failed"),
                    message: AppErrorMapper.userMessage(
                        for: error,
                        fallback: String(localized: "Failed to start preview.")
                    )
                )
            }
        }
    }

    private func stopPreview(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            guard let previewID = previewActions.previewIDForDisplayID(displayID) else {
                return
            }
            await previewActions.closePreview(previewID)
        }
    }

    private func startWebView(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            guard await prepareWebViewSharing() else { return }
            guard let display = await resolveDisplay(displayID: displayID) else {
                presentActionError(
                    title: String(localized: "Share Failed"),
                    message: String(localized: "Display is not available for sharing.")
                )
                return
            }
            do {
                _ = try await sharingAdapter.beginLANWebViewSharing(
                    display: display,
                    runtime: displayRuntime
                )
            } catch is CancellationError {
            } catch {
                await sharingAdapter.stopLANWebViewSharing(
                    displayID: displayID,
                    runtime: displayRuntime
                )
                presentActionError(
                    title: String(localized: "Share Failed"),
                    message: AppErrorMapper.userMessage(
                        for: error,
                        fallback: String(localized: "Failed to start sharing.")
                    )
                )
            }
        }
    }

    private func stopWebView(_ item: HomeVirtualDisplayItemPresentation) {
        guard let displayID = item.displayID else { return }
        Task {
            await sharingAdapter.stopLANWebViewSharing(
                displayID: displayID,
                runtime: displayRuntime
            )
        }
    }

    private func copyShareAddress(_ item: HomeVirtualDisplayItemPresentation) {
        guard let shareAddress = item.shareAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareAddress, forType: .string)
    }

    private func prepareWebViewSharing() async -> Bool {
        if !sharing.isWebServiceRunning {
            guard let requestedPort = requestedSharingPortForStart() else {
                return false
            }
            let result = await sharing.startWebService(requestedPort: requestedPort)
            if case .failed(let failure) = result {
                presentActionError(
                    title: String(localized: "Share Failed"),
                    message: failure.userMessage
                )
                return false
            }
        }
        await displayRuntime.handleSharingServiceStateChanged(isRunning: sharing.isWebServiceRunning)
        return sharing.isWebServiceRunning
    }

    private func requestedSharingPortForStart() -> UInt16? {
        switch SharePortValidationError.parse(sharingPortInput) {
        case .success(let port):
            sharingPortInput = String(port)
            sharingPortErrorMessage = nil
            return port
        case .failure(let validationError):
            sharingPortErrorMessage = validationError.userMessage
            return nil
        }
    }

    private func resolveDisplay(displayID: CGDirectDisplayID) async -> SCDisplay? {
        if let display = display(for: displayID) {
            return display
        }
        _ = await displayRuntime.forceRefreshCatalog(source: .capturePage)
        return display(for: displayID)
    }

    private func display(for displayID: CGDirectDisplayID) -> SCDisplay? {
        let displays =
            capture.displayCatalogState.activeShareableDisplays
            ?? sharing.displayCatalogState.activeShareableDisplays
            ?? []
        return displays.first { $0.displayID == displayID }
    }

    private func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName
            ?? String(localized: "Display")
    }

    private func resolutionText(for display: SCDisplay) -> String {
        "\(display.width) × \(display.height)"
    }

    private func canSetAsPrimary(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        guard item.desiredEnabled,
              !viewModel.isToggling(configId: item.id),
              !virtualDisplay.isRebuilding(configId: item.id)
        else {
            return false
        }
        let firstEnabledID = virtualDisplay.displayConfigs.first(where: \.desiredEnabled)?.id
        return firstEnabledID != item.id
    }

    private func isPreviewActionDisabled(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        if displayRuntime.isConsumerTransitionBusy(
            surfaceIdentity: .managedVirtualDisplay(configID: item.id)
        ) {
            return true
        }
        guard let displayID = item.displayID else { return true }
        if capture.isStarting(displayID: displayID) { return true }
        if item.isPreviewing { return false }
        return display(for: displayID) == nil
            || capture.displayCatalogState.hasScreenCapturePermission == false
    }

    private func needsDisplayDetection(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        guard capture.displayCatalogState.hasScreenCapturePermission == true,
              capture.displayCatalogState.loadErrorMessage == nil,
              capture.displayCatalogState.lastLoadError == nil,
              item.isRunning,
              !item.isPreviewing,
              !item.isSharing,
              let displayID = item.displayID
        else {
            return false
        }
        return display(for: displayID) == nil
    }

    private func isWebViewActionDisabled(_ item: HomeVirtualDisplayItemPresentation) -> Bool {
        if displayRuntime.isConsumerTransitionBusy(
            surfaceIdentity: .managedVirtualDisplay(configID: item.id)
        ) {
            return true
        }
        guard let displayID = item.displayID else { return true }
        if sharing.isStarting(displayID: displayID) { return true }
        if item.isSharing { return false }
        return display(for: displayID) == nil
            || capture.displayCatalogState.hasScreenCapturePermission == false
    }

    private func performPersistenceAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {}
    }

    private func presentActionError(title: String, message: String) {
        actionAlert = UserFacingAlertState(title: title, message: message)
    }

    private var sharePageAddresses: [CGDirectDisplayID: String] {
        let catalogDisplayIDs = Set(
            (sharing.displayCatalogState.activeShareableDisplays ?? []).map(\.displayID)
        )
        let displayIDs = catalogDisplayIDs
            .union(sharing.activeSharingDisplayIDs)
            .union(sharing.startingDisplayIDs)
        return Dictionary(
            uniqueKeysWithValues: displayIDs.compactMap { displayID in
                sharing.sharePageAddress(for: displayID).map { (displayID, $0) }
            }
        )
    }

    private var previewActions: CapturePreviewActions {
        CaptureUIComposition.previewActions(
            capture: capture,
            displayRuntime: displayRuntime,
            capturePerformancePreferences: capturePerformancePreferences
        )
    }

    private var permissionLabel: String {
        switch capture.displayCatalogState.hasScreenCapturePermission {
        case true:
            String(localized: "Allowed")
        case false:
            String(localized: "Permission Needed")
        case nil:
            String(localized: "Checking")
        }
    }

    private var permissionSystemImage: String {
        switch capture.displayCatalogState.hasScreenCapturePermission {
        case true:
            "checkmark.shield"
        case false:
            "lock.shield"
        case nil:
            "arrow.triangle.2.circlepath"
        }
    }

    private var permissionTint: Color {
        switch capture.displayCatalogState.hasScreenCapturePermission {
        case true:
            .green
        case false:
            .orange
        case nil:
            .blue
        }
    }

    private var isSharingPortDirty: Bool {
        sharingPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
            != String(sharing.preferredWebServicePort)
    }
}
