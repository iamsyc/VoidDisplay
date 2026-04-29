import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation

private let defaultSharingPort: UInt16 = 8089

/// Shared key used by persistence and launch-argument injection:
/// `-sharing.preferredPort <port>`
public enum SharingPortPreferenceKeys {
    public static let preferredPort = "sharing.preferredPort"
}

@MainActor
package protocol SharingPortPreferencesProtocol: AnyObject {
    var preferredPort: UInt16 { get }
    func savePreferredPort(_ port: UInt16)
}

@MainActor
package final class SharingPortPreferences: SharingPortPreferencesProtocol {
    private let defaults: UserDefaults
    private let defaultPort: UInt16

    package init(
        defaults: UserDefaults,
        defaultPort: UInt16 = defaultSharingPort
    ) {
        self.defaults = defaults
        self.defaultPort = defaultPort
    }

    package var preferredPort: UInt16 {
        let value = defaults.integer(forKey: SharingPortPreferenceKeys.preferredPort)
        guard value != 0,
              let port = UInt16(exactly: value),
              (1024...65535).contains(Int(port)) else {
            return defaultPort
        }
        return port
    }

    package func savePreferredPort(_ port: UInt16) {
        defaults.set(Int(port), forKey: SharingPortPreferenceKeys.preferredPort)
    }
}
