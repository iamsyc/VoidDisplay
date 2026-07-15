import Foundation

package typealias DisplayRuntimeDisplayID = UInt32

package nonisolated struct DisplayRuntimeCatalogSnapshot: Codable, Equatable, Sendable {
    package let hasScreenCapturePermission: Bool?
    package let lastPreflightPermission: Bool?
    package let lastRequestPermission: Bool?
    package let isLoadingDisplays: Bool
    package let hasLoadError: Bool
    package let lastLoadError: DisplayRuntimeCatalogLoadError?
    package let loadedDisplays: [DisplayRuntimeCatalogDisplay]
    package let topologySignature: [DisplayRuntimeCatalogTopologyEntry]

    package init(
        hasScreenCapturePermission: Bool?,
        lastPreflightPermission: Bool?,
        lastRequestPermission: Bool?,
        isLoadingDisplays: Bool,
        hasLoadError: Bool,
        lastLoadError: DisplayRuntimeCatalogLoadError?,
        loadedDisplays: [DisplayRuntimeCatalogDisplay],
        topologySignature: [DisplayRuntimeCatalogTopologyEntry]
    ) {
        self.hasScreenCapturePermission = hasScreenCapturePermission
        self.lastPreflightPermission = lastPreflightPermission
        self.lastRequestPermission = lastRequestPermission
        self.isLoadingDisplays = isLoadingDisplays
        self.hasLoadError = hasLoadError
        self.lastLoadError = lastLoadError
        self.loadedDisplays = loadedDisplays.sorted { $0.displayID < $1.displayID }
        self.topologySignature = topologySignature.sorted { $0.displayID < $1.displayID }
    }

    package static let empty = Self(
        hasScreenCapturePermission: nil,
        lastPreflightPermission: nil,
        lastRequestPermission: nil,
        isLoadingDisplays: false,
        hasLoadError: false,
        lastLoadError: nil,
        loadedDisplays: [],
        topologySignature: []
    )
}

package nonisolated struct DisplayRuntimeCatalogLoadError: Codable, Equatable, Sendable {
    package let domain: String
    package let code: Int
    package let hasDescription: Bool
    package let hasFailureReason: Bool
    package let hasRecoverySuggestion: Bool

    package init(
        domain: String,
        code: Int,
        hasDescription: Bool,
        hasFailureReason: Bool,
        hasRecoverySuggestion: Bool
    ) {
        self.domain = domain
        self.code = code
        self.hasDescription = hasDescription
        self.hasFailureReason = hasFailureReason
        self.hasRecoverySuggestion = hasRecoverySuggestion
    }
}

package nonisolated struct DisplayRuntimeCatalogDisplay: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let pixelWidth: Int?
    package let pixelHeight: Int?

    package init(
        displayID: DisplayRuntimeDisplayID,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

package nonisolated struct DisplayRuntimeCatalogTopologyEntry: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let isMain: Bool
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let refreshRateMilliHertz: Int?
    package let mirrorsDisplayID: DisplayRuntimeDisplayID?

    package init(
        displayID: DisplayRuntimeDisplayID,
        isMain: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRateMilliHertz: Int?,
        mirrorsDisplayID: DisplayRuntimeDisplayID?
    ) {
        self.displayID = displayID
        self.isMain = isMain
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateMilliHertz = refreshRateMilliHertz
        self.mirrorsDisplayID = mirrorsDisplayID
    }
}
