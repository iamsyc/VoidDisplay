import Foundation

package nonisolated enum DisplayRuntimeConsumerDemandAggregator {
    package static func aggregate(
        surfaceIdentity: DisplaySurfaceIdentity,
        surfaceEpoch: DisplaySurfaceEpoch,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        leases: [DisplayRuntimeConsumerLease]
    ) -> DisplayRuntimeAggregatedDemand? {
        let activeLeases = leases
            .filter { $0.surfaceIdentity == surfaceIdentity }
            .filter { $0.surfaceEpoch == surfaceEpoch }
            .filter { $0.state.contributesDemand }

        guard !activeLeases.isEmpty else { return nil }

        let activeDemands = activeLeases.map(\.demand)
        let permitsExplicitDowngrade = activeDemands.allSatisfy {
            $0.powerProfile == .powerEfficient
        }

        return DisplayRuntimeAggregatedDemand(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: surfaceEpoch,
            resolvedDisplayID: resolvedDisplayID,
            activeLeaseIDs: activeLeases.map(\.id),
            consumerKinds: Array(Set(activeLeases.map(\.kind))),
            effectivePixelSize: effectivePixelSize(
                demands: activeDemands,
                permitsExplicitDowngrade: permitsExplicitDowngrade
            ),
            effectiveFramesPerSecond: effectiveFramesPerSecond(
                demands: activeDemands,
                permitsExplicitDowngrade: permitsExplicitDowngrade
            ),
            capturesCursor: activeDemands.contains(where: \.capturesCursor),
            qualityProfile: qualityProfile(for: activeLeases.map(\.kind)),
            powerProfile: powerProfile(for: activeDemands),
            latencyPreference: latencyPreference(for: activeDemands),
            activeViewerCount: activeDemands.reduce(0) { $0 + $1.activeViewerCount },
            permitsExplicitDowngrade: permitsExplicitDowngrade
        )
    }

    private static func effectivePixelSize(
        demands: [DisplayRuntimeConsumerDemand],
        permitsExplicitDowngrade: Bool
    ) -> DisplayRuntimePixelSize? {
        if permitsExplicitDowngrade {
            return largestPixelSize(
                demands.compactMap {
                    $0.preferredPixelSize ?? $0.maximumPixelSize ?? $0.sourcePixelSize
                }
            )
        }

        let sourceSizes = demands.compactMap(\.sourcePixelSize)
        if let sourceSize = largestPixelSize(sourceSizes) {
            return sourceSize
        }

        return largestPixelSize(
            demands.flatMap {
                [$0.preferredPixelSize, $0.maximumPixelSize].compactMap(\.self)
            }
        )
    }

    private static func effectiveFramesPerSecond(
        demands: [DisplayRuntimeConsumerDemand],
        permitsExplicitDowngrade: Bool
    ) -> Int? {
        if permitsExplicitDowngrade {
            return demands.compactMap { $0.preferredFramesPerSecond ?? $0.sourceFramesPerSecond }.max()
        }

        let sourceFrameRates = demands.compactMap(\.sourceFramesPerSecond)
        if let sourceFrameRate = sourceFrameRates.max() {
            return sourceFrameRate
        }

        return demands.compactMap(\.preferredFramesPerSecond).max()
    }

    private static func largestPixelSize(_ values: [DisplayRuntimePixelSize]) -> DisplayRuntimePixelSize? {
        values.max()
    }

    private static func qualityProfile(
        for kinds: [DisplaySurfaceConsumerKind]
    ) -> DisplayRuntimeAggregateQualityProfile {
        let uniqueKinds = Set(kinds)
        if uniqueKinds.count > 1 {
            return .mixed
        }
        switch uniqueKinds.first {
        case .preview:
            return .previewOnly
        case .lanWebView:
            return .lanWebViewOnly
        case .diagnosticsRecorder:
            return .diagnosticsOnly
        case nil:
            return .mixed
        }
    }

    private static func powerProfile(
        for demands: [DisplayRuntimeConsumerDemand]
    ) -> DisplayRuntimeCapturePowerProfile {
        if demands.contains(where: { $0.powerProfile == .smooth }) {
            return .smooth
        }
        if demands.contains(where: { $0.powerProfile == .automatic }) {
            return .automatic
        }
        return .powerEfficient
    }

    private static func latencyPreference(
        for demands: [DisplayRuntimeConsumerDemand]
    ) -> DisplayRuntimeConsumerLatencyPreference {
        demands
            .map(\.latencyPreference)
            .max { $0.priority < $1.priority } ?? .balanced
    }
}
