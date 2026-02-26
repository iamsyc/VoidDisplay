import Foundation

@MainActor
protocol SharingPortPreferencesProtocol: AnyObject {
    var preferredPort: UInt16 { get }
    func savePreferredPort(_ port: UInt16)
}

@MainActor
final class SharingPortPreferences: SharingPortPreferencesProtocol {
    private enum Keys {
        static let preferredPort = "sharing.preferredPort"
    }

    private let defaults: UserDefaults
    private let defaultPort: UInt16

    init(
        defaults: UserDefaults = .standard,
        defaultPort: UInt16 = 8081
    ) {
        self.defaults = defaults
        self.defaultPort = defaultPort
    }

    var preferredPort: UInt16 {
        let value = defaults.integer(forKey: Keys.preferredPort)
        guard value != 0,
              let port = UInt16(exactly: value),
              (1024...65535).contains(Int(port)) else {
            return defaultPort
        }
        return port
    }

    func savePreferredPort(_ port: UInt16) {
        defaults.set(Int(port), forKey: Keys.preferredPort)
    }
}
