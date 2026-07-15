import Foundation

package nonisolated struct DisplayRuntimePixelSize: Codable, Comparable, Equatable, Hashable, Sendable {
    package let width: Int
    package let height: Int

    package init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsArea = lhs.width.multipliedReportingOverflow(by: lhs.height)
        let rhsArea = rhs.width.multipliedReportingOverflow(by: rhs.height)
        let lhsValue = lhsArea.overflow ? Int.max : lhsArea.partialValue
        let rhsValue = rhsArea.overflow ? Int.max : rhsArea.partialValue
        if lhsValue != rhsValue { return lhsValue < rhsValue }
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        return lhs.height < rhs.height
    }
}

package nonisolated enum DisplayRuntimeCapturePowerProfile: String, Codable, Equatable, Sendable {
    case automatic
    case smooth
    case powerEfficient
}

package nonisolated enum DisplayRuntimeConsumerLatencyPreference: String, Codable, Equatable, Sendable {
    case realtime
    case balanced
    case recording

    package var priority: Int {
        switch self {
        case .realtime: 3
        case .balanced: 2
        case .recording: 1
        }
    }
}

package nonisolated struct DisplayRuntimeConsumerDemand: Codable, Equatable, Sendable {
    package let sourcePixelSize: DisplayRuntimePixelSize?
    package let preferredPixelSize: DisplayRuntimePixelSize?
    package let maximumPixelSize: DisplayRuntimePixelSize?
    package let sourceFramesPerSecond: Int?
    package let preferredFramesPerSecond: Int?
    package let capturesCursor: Bool
    package let powerProfile: DisplayRuntimeCapturePowerProfile
    package let latencyPreference: DisplayRuntimeConsumerLatencyPreference
    package let activeViewerCount: Int

    package init(
        sourcePixelSize: DisplayRuntimePixelSize? = nil,
        preferredPixelSize: DisplayRuntimePixelSize? = nil,
        maximumPixelSize: DisplayRuntimePixelSize? = nil,
        sourceFramesPerSecond: Int? = nil,
        preferredFramesPerSecond: Int? = nil,
        capturesCursor: Bool,
        powerProfile: DisplayRuntimeCapturePowerProfile,
        latencyPreference: DisplayRuntimeConsumerLatencyPreference,
        activeViewerCount: Int = 0
    ) {
        self.sourcePixelSize = sourcePixelSize
        self.preferredPixelSize = preferredPixelSize
        self.maximumPixelSize = maximumPixelSize
        self.sourceFramesPerSecond = sourceFramesPerSecond.map { max(1, $0) }
        self.preferredFramesPerSecond = preferredFramesPerSecond.map { max(1, $0) }
        self.capturesCursor = capturesCursor
        self.powerProfile = powerProfile
        self.latencyPreference = latencyPreference
        self.activeViewerCount = max(0, activeViewerCount)
    }

    package func replacing(
        capturesCursor: Bool? = nil,
        powerProfile: DisplayRuntimeCapturePowerProfile? = nil,
        activeViewerCount: Int? = nil
    ) -> Self {
        Self(
            sourcePixelSize: sourcePixelSize,
            preferredPixelSize: preferredPixelSize,
            maximumPixelSize: maximumPixelSize,
            sourceFramesPerSecond: sourceFramesPerSecond,
            preferredFramesPerSecond: preferredFramesPerSecond,
            capturesCursor: capturesCursor ?? self.capturesCursor,
            powerProfile: powerProfile ?? self.powerProfile,
            latencyPreference: latencyPreference,
            activeViewerCount: activeViewerCount ?? self.activeViewerCount
        )
    }
}

package nonisolated enum DisplayRuntimeAggregateQualityProfile: String, Codable, Equatable, Sendable {
    case previewOnly
    case lanWebViewOnly
    case mixed
}

package nonisolated struct DisplayRuntimeAggregatedDemand: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let surfaceEpoch: DisplaySurfaceEpoch
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let activeLeaseIDs: [DisplayRuntimeConsumerLeaseID]
    package let consumerKinds: [DisplaySurfaceConsumerKind]
    package let effectivePixelSize: DisplayRuntimePixelSize?
    package let effectiveFramesPerSecond: Int?
    package let capturesCursor: Bool
    package let qualityProfile: DisplayRuntimeAggregateQualityProfile
    package let powerProfile: DisplayRuntimeCapturePowerProfile
    package let latencyPreference: DisplayRuntimeConsumerLatencyPreference
    package let activeViewerCount: Int
    package let permitsExplicitDowngrade: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        surfaceEpoch: DisplaySurfaceEpoch,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        activeLeaseIDs: [DisplayRuntimeConsumerLeaseID],
        consumerKinds: [DisplaySurfaceConsumerKind],
        effectivePixelSize: DisplayRuntimePixelSize?,
        effectiveFramesPerSecond: Int?,
        capturesCursor: Bool,
        qualityProfile: DisplayRuntimeAggregateQualityProfile,
        powerProfile: DisplayRuntimeCapturePowerProfile,
        latencyPreference: DisplayRuntimeConsumerLatencyPreference,
        activeViewerCount: Int,
        permitsExplicitDowngrade: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.surfaceEpoch = surfaceEpoch
        self.resolvedDisplayID = resolvedDisplayID
        self.activeLeaseIDs = activeLeaseIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        self.consumerKinds = consumerKinds.sorted { $0.rawValue < $1.rawValue }
        self.effectivePixelSize = effectivePixelSize
        self.effectiveFramesPerSecond = effectiveFramesPerSecond
        self.capturesCursor = capturesCursor
        self.qualityProfile = qualityProfile
        self.powerProfile = powerProfile
        self.latencyPreference = latencyPreference
        self.activeViewerCount = max(0, activeViewerCount)
        self.permitsExplicitDowngrade = permitsExplicitDowngrade
    }
}
