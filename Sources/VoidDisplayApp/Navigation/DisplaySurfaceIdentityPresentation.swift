import CoreGraphics
import Foundation
import VoidDisplayRuntime
enum DisplaySurfaceIdentityPresentation {
static func title(
        for surface: DisplaySurface,
        ordinal: Int?,
        virtualDisplayNamesByConfigID: [UUID: String]
    ) -> String {
        switch surface.kind {
        case .managedVirtualDisplay:
            if let configID = surface.managedVirtualDisplay?.configID,
               let displayName = virtualDisplayNamesByConfigID[configID]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                return displayName
            }
            if let ordinal {
                return String(format: String(localized: "Virtual Display %lld"), Int64(ordinal))
            } else {
                return String(localized: "Virtual Display")
            }
        case .physicalDisplay:
            if let ordinal {
                return String(format: String(localized: "Physical Display %lld"), Int64(ordinal))
            } else {
                return String(localized: "Physical Display")
            }
        }
    }

    static func subtitle(for surface: DisplaySurface) -> String {
        pixelResolutionText(for: surface) ?? String(localized: "Resolution unavailable")
    }

    static func redactedIdentityText(for identity: DisplaySurfaceIdentity) -> String {
        let digest = redactedDigest(for: "\(identity.kind.rawValue):\(identity.stableID)")
        return String(format: String(localized: "ID hash %@"), digest)
    }

    static func redactedDigest(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%06llx", hash & 0xFF_FFFF)
    }

    static func pixelResolutionText(for surface: DisplaySurface) -> String? {
        if let catalog = surface.catalog,
           let width = catalog.pixelWidth,
           let height = catalog.pixelHeight {
            return String(format: String(localized: "%lld × %lld pixels"), Int64(width), Int64(height))
        }
        if let managed = surface.managedVirtualDisplay,
           let width = managed.maximumPixelWidth,
           let height = managed.maximumPixelHeight {
            return String(format: String(localized: "%lld × %lld pixels"), Int64(width), Int64(height))
        }
        return nil
    }
}
