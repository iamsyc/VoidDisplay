import Foundation
import SwiftUI
import VoidDisplayFoundation

package enum HomeVirtualDisplayItemAction {
    case toggle
    case preview
    case webView
    case openSharePage
    case copyShareAddress
    case edit
    case moveUp
    case moveDown
    case setPrimary
    case retryRebuild
    case delete
}

package struct HomeVirtualDisplayItemRenderState: Identifiable {
    package let item: HomeVirtualDisplayItemPresentation
    package let isFirst: Bool
    package let isLast: Bool
    package let isToggling: Bool
    package let isRebuilding: Bool
    package let hasRecentApplySuccess: Bool
    package let rebuildFailureMessage: String?
    package let isPrimary: Bool
    package let canSetAsPrimary: Bool
    package let isPreviewActionDisabled: Bool
    package let isPreviewStarting: Bool
    package let isWebViewActionDisabled: Bool
    package let isWebViewStarting: Bool

    package var id: UUID { item.id }

    package init(
        item: HomeVirtualDisplayItemPresentation,
        isFirst: Bool,
        isLast: Bool,
        isToggling: Bool,
        isRebuilding: Bool,
        hasRecentApplySuccess: Bool,
        rebuildFailureMessage: String?,
        isPrimary: Bool,
        canSetAsPrimary: Bool,
        isPreviewActionDisabled: Bool,
        isPreviewStarting: Bool,
        isWebViewActionDisabled: Bool,
        isWebViewStarting: Bool
    ) {
        self.item = item
        self.isFirst = isFirst
        self.isLast = isLast
        self.isToggling = isToggling
        self.isRebuilding = isRebuilding
        self.hasRecentApplySuccess = hasRecentApplySuccess
        self.rebuildFailureMessage = rebuildFailureMessage
        self.isPrimary = isPrimary
        self.canSetAsPrimary = canSetAsPrimary
        self.isPreviewActionDisabled = isPreviewActionDisabled
        self.isPreviewStarting = isPreviewStarting
        self.isWebViewActionDisabled = isWebViewActionDisabled
        self.isWebViewStarting = isWebViewStarting
    }
}

package struct HomePermissionStatusRenderState {
    package let label: String
    package let systemImage: String
    package let tint: Color
    package let isActive: Bool
    package let canOpenSettings: Bool

    package init(
        label: String,
        systemImage: String,
        tint: Color,
        isActive: Bool,
        canOpenSettings: Bool
    ) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.isActive = isActive
        self.canOpenSettings = canOpenSettings
    }
}

package struct HomeSharingSettingsRenderState {
    package let performanceMode: CapturePerformanceMode
    package let portInput: String
    package let isPortDirty: Bool
    package let portErrorMessage: String?
    package let isWebServiceRunning: Bool
    package let webServicePortValue: UInt16

    package init(
        performanceMode: CapturePerformanceMode,
        portInput: String,
        isPortDirty: Bool,
        portErrorMessage: String?,
        isWebServiceRunning: Bool,
        webServicePortValue: UInt16
    ) {
        self.performanceMode = performanceMode
        self.portInput = portInput
        self.isPortDirty = isPortDirty
        self.portErrorMessage = portErrorMessage
        self.isWebServiceRunning = isWebServiceRunning
        self.webServicePortValue = webServicePortValue
    }
}

package struct HomeLayoutActions {
    package let createVirtualDisplay: @MainActor () -> Void
    package let refresh: @MainActor () -> Void
    package let openScreenCapturePrivacySettings: @MainActor () -> Void
    package let performItemAction: @MainActor (
        HomeVirtualDisplayItemAction,
        HomeVirtualDisplayItemPresentation
    ) -> Void
    package let setCapturePerformanceMode: @MainActor (CapturePerformanceMode) -> Void
    package let updateSharingPortDraft: @MainActor (String) -> Void
    package let applySharingPortDraft: @MainActor () -> Void

    package init(
        createVirtualDisplay: @escaping @MainActor () -> Void,
        refresh: @escaping @MainActor () -> Void,
        openScreenCapturePrivacySettings: @escaping @MainActor () -> Void,
        performItemAction: @escaping @MainActor (
            HomeVirtualDisplayItemAction,
            HomeVirtualDisplayItemPresentation
        ) -> Void,
        setCapturePerformanceMode: @escaping @MainActor (CapturePerformanceMode) -> Void,
        updateSharingPortDraft: @escaping @MainActor (String) -> Void,
        applySharingPortDraft: @escaping @MainActor () -> Void
    ) {
        self.createVirtualDisplay = createVirtualDisplay
        self.refresh = refresh
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
        self.performItemAction = performItemAction
        self.setCapturePerformanceMode = setCapturePerformanceMode
        self.updateSharingPortDraft = updateSharingPortDraft
        self.applySharingPortDraft = applySharingPortDraft
    }

    @MainActor
    package func perform(
        _ action: HomeVirtualDisplayItemAction,
        for state: HomeVirtualDisplayItemRenderState
    ) {
        performItemAction(action, state.item)
    }
}

package struct HomeLayoutContext {
    package let metrics: HomeLayoutMetrics
    package let presentation: HomeVirtualDisplaySurfacePresentation
    package let itemStates: [HomeVirtualDisplayItemRenderState]
    package let isCreateVirtualDisplayDisabled: Bool
    package let permissionStatus: HomePermissionStatusRenderState
    package let sharingSettings: HomeSharingSettingsRenderState
    package let actions: HomeLayoutActions

    package var summary: HomeRuntimeSummaryPresentation {
        presentation.summary
    }

    package var items: [HomeVirtualDisplayItemPresentation] {
        presentation.items
    }

    package init(
        metrics: HomeLayoutMetrics,
        presentation: HomeVirtualDisplaySurfacePresentation,
        itemStates: [HomeVirtualDisplayItemRenderState],
        isCreateVirtualDisplayDisabled: Bool,
        permissionStatus: HomePermissionStatusRenderState,
        sharingSettings: HomeSharingSettingsRenderState,
        actions: HomeLayoutActions
    ) {
        self.metrics = metrics
        self.presentation = presentation
        self.itemStates = itemStates
        self.isCreateVirtualDisplayDisabled = isCreateVirtualDisplayDisabled
        self.permissionStatus = permissionStatus
        self.sharingSettings = sharingSettings
        self.actions = actions
    }
}
