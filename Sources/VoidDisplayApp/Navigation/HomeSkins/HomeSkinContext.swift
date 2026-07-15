import Foundation
import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayFoundation

package enum HomeVirtualDisplayCardAction {
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

package struct HomeVirtualDisplayCardRenderState: Identifiable {
    package let card: HomeVirtualDisplayCardPresentation
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

    package var id: UUID { card.id }

    package init(
        card: HomeVirtualDisplayCardPresentation,
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
        self.card = card
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

package struct HomeSkinActions {
    package let createVirtualDisplay: @MainActor () -> Void
    package let refresh: @MainActor () -> Void
    package let openScreenCapturePrivacySettings: @MainActor () -> Void
    package let performCardAction: @MainActor (
        HomeVirtualDisplayCardAction,
        HomeVirtualDisplayCardPresentation
    ) -> Void
    package let setCapturePerformanceMode: @MainActor (CapturePerformanceMode) -> Void
    package let updateSharingPortDraft: @MainActor (String) -> Void
    package let applySharingPortDraft: @MainActor () -> Void

    package init(
        createVirtualDisplay: @escaping @MainActor () -> Void,
        refresh: @escaping @MainActor () -> Void,
        openScreenCapturePrivacySettings: @escaping @MainActor () -> Void,
        performCardAction: @escaping @MainActor (
            HomeVirtualDisplayCardAction,
            HomeVirtualDisplayCardPresentation
        ) -> Void,
        setCapturePerformanceMode: @escaping @MainActor (CapturePerformanceMode) -> Void,
        updateSharingPortDraft: @escaping @MainActor (String) -> Void,
        applySharingPortDraft: @escaping @MainActor () -> Void
    ) {
        self.createVirtualDisplay = createVirtualDisplay
        self.refresh = refresh
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
        self.performCardAction = performCardAction
        self.setCapturePerformanceMode = setCapturePerformanceMode
        self.updateSharingPortDraft = updateSharingPortDraft
        self.applySharingPortDraft = applySharingPortDraft
    }

    @MainActor
    package func perform(
        _ action: HomeVirtualDisplayCardAction,
        for state: HomeVirtualDisplayCardRenderState
    ) {
        performCardAction(action, state.card)
    }
}

package struct HomeSkinContext {
    package let presentation: HomeVirtualDisplaySurfacePresentation
    package let cardStates: [HomeVirtualDisplayCardRenderState]
    package let theme: AppTheme
    package let isCreateVirtualDisplayDisabled: Bool
    package let permissionStatus: HomePermissionStatusRenderState
    package let sharingSettings: HomeSharingSettingsRenderState
    package let actions: HomeSkinActions

    package var summary: HomeRuntimeSummaryPresentation {
        presentation.summary
    }

    package var cards: [HomeVirtualDisplayCardPresentation] {
        presentation.cards
    }

    package init(
        presentation: HomeVirtualDisplaySurfacePresentation,
        cardStates: [HomeVirtualDisplayCardRenderState],
        theme: AppTheme,
        isCreateVirtualDisplayDisabled: Bool,
        permissionStatus: HomePermissionStatusRenderState,
        sharingSettings: HomeSharingSettingsRenderState,
        actions: HomeSkinActions
    ) {
        self.presentation = presentation
        self.cardStates = cardStates
        self.theme = theme
        self.isCreateVirtualDisplayDisabled = isCreateVirtualDisplayDisabled
        self.permissionStatus = permissionStatus
        self.sharingSettings = sharingSettings
        self.actions = actions
    }
}
