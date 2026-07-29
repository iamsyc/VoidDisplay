import Foundation
import VoidDisplayRuntime

package enum HomeDisplayDetectionPresentation: Hashable {
    case idle
    case scanning
    case updated(displayCount: Int)
    case upToDate(displayCount: Int)
    case permissionRequired
    case failed

    package static func completion(
        previousCatalog: DisplayRuntimeCatalogSnapshot,
        currentCatalog: DisplayRuntimeCatalogSnapshot
    ) -> Self {
        if currentCatalog.hasScreenCapturePermission == false {
            return .permissionRequired
        }
        if currentCatalog.hasLoadError {
            return .failed
        }

        let didChange =
            previousCatalog.loadedDisplays != currentCatalog.loadedDisplays
            || previousCatalog.topologySignature != currentCatalog.topologySignature
        let displayCount = currentCatalog.loadedDisplays.count
        return didChange ? .updated(displayCount: displayCount) : .upToDate(displayCount: displayCount)
    }

    package var isScanning: Bool {
        self == .scanning
    }

    package var showsStatus: Bool {
        switch self {
        case .scanning, .updated, .upToDate, .failed:
            true
        case .idle, .permissionRequired:
            false
        }
    }

    package var showsRetryAction: Bool {
        self == .failed
    }

    package var isTransient: Bool {
        switch self {
        case .updated, .upToDate:
            true
        case .idle, .scanning, .permissionRequired, .failed:
            false
        }
    }

    package var toolbarTitle: String {
        String(localized: "Rescan Displays")
    }

    package var toolbarAccessibilityValue: String {
        isScanning ? String(localized: "Detecting Displays…") : ""
    }

    package var message: String {
        switch self {
        case .idle:
            ""
        case .scanning:
            String(localized: "Detecting displays available for preview and sharing…")
        case .updated(let displayCount):
            String.localizedStringWithFormat(
                String(localized: "Detected Displays: %lld"),
                Int64(displayCount)
            )
        case .upToDate:
            String(localized: "Display list is up to date.")
        case .permissionRequired:
            String(localized: "Screen Recording Permission Required")
        case .failed:
            String(localized: "Couldn’t Detect Displays")
        }
    }

    package var systemImage: String {
        switch self {
        case .idle, .scanning:
            "arrow.clockwise"
        case .updated, .upToDate:
            "checkmark.circle.fill"
        case .permissionRequired:
            "lock.shield"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    package var tone: DisplaySurfaceStatusTone {
        switch self {
        case .idle, .upToDate:
            .neutral
        case .scanning:
            .info
        case .updated:
            .success
        case .permissionRequired, .failed:
            .warning
        }
    }
}
