import CoreGraphics
import Foundation
import VoidDisplayRuntime
package struct DisplaySurfaceListPresentation: Equatable {
    package let surfaces: [DisplaySurfacePresentation]

    package init(surfaces: [DisplaySurfacePresentation]) {
        self.surfaces = surfaces
    }
}

package struct DisplaySurfacePresentation: Identifiable, Equatable {
    package let id: String
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let displayID: CGDirectDisplayID?
    package let title: String
    package let subtitle: String
    package let isManagedVirtualDisplay: Bool
    package let isPreviewing: Bool
    package let isSharing: Bool
    package let rowActions: [DisplaySurfaceRowActionPresentation]
    package let compactStatusItems: [DisplaySurfaceStatusItemPresentation]
    package let technicalStatusItems: [DisplaySurfaceStatusItemPresentation]
    package let accessibilitySummary: String

    package init(
        id: String,
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: CGDirectDisplayID?,
        title: String,
        subtitle: String,
        isManagedVirtualDisplay: Bool,
        isPreviewing: Bool,
        isSharing: Bool,
        rowActions: [DisplaySurfaceRowActionPresentation],
        compactStatusItems: [DisplaySurfaceStatusItemPresentation],
        technicalStatusItems: [DisplaySurfaceStatusItemPresentation],
        accessibilitySummary: String
    ) {
        self.id = id
        self.surfaceIdentity = surfaceIdentity
        self.displayID = displayID
        self.title = title
        self.subtitle = subtitle
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
        self.isPreviewing = isPreviewing
        self.isSharing = isSharing
        self.rowActions = rowActions
        self.compactStatusItems = compactStatusItems
        self.technicalStatusItems = technicalStatusItems
        self.accessibilitySummary = accessibilitySummary
    }
}

package enum DisplaySurfaceRowActionKind: String, Equatable {
    case openPreview
    case stopPreview
    case openLANWebView
    case stopLANWebView
}

package struct DisplaySurfaceRowActionPresentation: Identifiable, Equatable {
    package let kind: DisplaySurfaceRowActionKind
    package let title: String
    package let help: String
    package let systemImage: String
    package let accessibilityIdentifier: String
    package let isEnabled: Bool
    package let isDestructive: Bool

    package var id: String {
        kind.rawValue
    }

    package init(
        kind: DisplaySurfaceRowActionKind,
        title: String,
        help: String? = nil,
        systemImage: String,
        accessibilityIdentifier: String,
        isEnabled: Bool,
        isDestructive: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.help = help ?? title
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
    }
}

package struct DisplaySurfaceStatusItemPresentation: Identifiable, Equatable {
    package let id: String
    package let title: String
    package let value: String
    package let accessibilityIdentifier: String
    package let tone: DisplaySurfaceStatusTone
    package let isFailureCode: Bool

    package init(
        id: String,
        title: String,
        value: String,
        accessibilityIdentifier: String,
        tone: DisplaySurfaceStatusTone = .neutral,
        isFailureCode: Bool = false
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
        self.tone = tone
        self.isFailureCode = isFailureCode
    }
}

package enum DisplaySurfaceStatusTone: Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}
