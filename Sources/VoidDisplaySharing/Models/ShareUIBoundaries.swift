import CoreGraphics
import Foundation

@MainActor
package struct ShareCatalogActions {
    package var handleAppear: @MainActor () async -> Void
    package var handleDisappear: @MainActor () async -> Void
    package var handleTopologyChanged: @MainActor () async -> Void
    package var requestPermission: @MainActor () async -> Void
    package var refreshPermission: @MainActor () async -> Void
    package var forceRefresh: @MainActor () async -> Void
    package var handleSharingServiceStateChanged: @MainActor (Bool) async -> Void
    package var openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    package init(
        handleAppear: @escaping @MainActor () async -> Void,
        handleDisappear: @escaping @MainActor () async -> Void,
        handleTopologyChanged: @escaping @MainActor () async -> Void,
        requestPermission: @escaping @MainActor () async -> Void,
        refreshPermission: @escaping @MainActor () async -> Void,
        forceRefresh: @escaping @MainActor () async -> Void,
        handleSharingServiceStateChanged: @escaping @MainActor (Bool) async -> Void,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) {
        self.handleAppear = handleAppear
        self.handleDisappear = handleDisappear
        self.handleTopologyChanged = handleTopologyChanged
        self.requestPermission = requestPermission
        self.refreshPermission = refreshPermission
        self.forceRefresh = forceRefresh
        self.handleSharingServiceStateChanged = handleSharingServiceStateChanged
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
    }

    package static let noop = ShareCatalogActions(
        handleAppear: {},
        handleDisappear: {},
        handleTopologyChanged: {},
        requestPermission: {},
        refreshPermission: {},
        forceRefresh: {},
        handleSharingServiceStateChanged: { _ in },
        openScreenCapturePrivacySettings: { _ in }
    )
}

package struct ShareDisplayStatus: Equatable, Sendable {
    package var isPreviewing: Bool
    package var isManagedVirtualDisplay: Bool

    package init(isPreviewing: Bool, isManagedVirtualDisplay: Bool) {
        self.isPreviewing = isPreviewing
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
    }

    package static let inactive = ShareDisplayStatus(
        isPreviewing: false,
        isManagedVirtualDisplay: false
    )
}

package struct ShareRuntimeState: Equatable, Sendable {
    package var isWebServiceRunning: Bool
    package var activeSharingDisplayIDs: Set<CGDirectDisplayID>
    package var startingDisplayIDs: Set<CGDirectDisplayID>
    package var sharingClientCount: Int
    package var sharingClientCounts: [CGDirectDisplayID: Int]
    package var sharePageAddresses: [CGDirectDisplayID: String]

    package init(
        isWebServiceRunning: Bool,
        activeSharingDisplayIDs: Set<CGDirectDisplayID>,
        startingDisplayIDs: Set<CGDirectDisplayID>,
        sharingClientCount: Int,
        sharingClientCounts: [CGDirectDisplayID: Int],
        sharePageAddresses: [CGDirectDisplayID: String]
    ) {
        self.isWebServiceRunning = isWebServiceRunning
        self.activeSharingDisplayIDs = activeSharingDisplayIDs
        self.startingDisplayIDs = startingDisplayIDs
        self.sharingClientCount = sharingClientCount
        self.sharingClientCounts = sharingClientCounts
        self.sharePageAddresses = sharePageAddresses
    }

    package func isDisplaySharing(displayID: CGDirectDisplayID) -> Bool {
        activeSharingDisplayIDs.contains(displayID)
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startingDisplayIDs.contains(displayID)
    }

    package func displayClientCount(for displayID: CGDirectDisplayID) -> Int {
        sharingClientCounts[displayID] ?? 0
    }

    package func sharePageAddress(for displayID: CGDirectDisplayID) -> String? {
        sharePageAddresses[displayID]
    }

    package static let inactive = ShareRuntimeState(
        isWebServiceRunning: false,
        activeSharingDisplayIDs: [],
        startingDisplayIDs: [],
        sharingClientCount: 0,
        sharingClientCounts: [:],
        sharePageAddresses: [:]
    )
}

@MainActor
package struct ShareDisplayStatusProvider {
    package var status: @MainActor (CGDirectDisplayID) -> ShareDisplayStatus

    package init(status: @escaping @MainActor (CGDirectDisplayID) -> ShareDisplayStatus) {
        self.status = status
    }

    package static let none = ShareDisplayStatusProvider { _ in .inactive }
}

package enum SharePerformanceMode: String, CaseIterable, Sendable {
    case automatic
    case smooth
    case powerEfficient
}

@MainActor
package struct SharePerformanceModeBinding {
    package var get: @MainActor () -> SharePerformanceMode
    package var set: @MainActor (SharePerformanceMode) -> Void

    package init(
        get: @escaping @MainActor () -> SharePerformanceMode,
        set: @escaping @MainActor (SharePerformanceMode) -> Void
    ) {
        self.get = get
        self.set = set
    }

    package static let automatic = SharePerformanceModeBinding(
        get: { .automatic },
        set: { _ in }
    )
}
