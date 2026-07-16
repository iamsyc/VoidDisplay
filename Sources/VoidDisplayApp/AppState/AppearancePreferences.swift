import Foundation
import Observation

package enum AppearancePreferenceKeys {
    package static let homeLayoutID = "appearance.homeLayoutID"
}

@MainActor
@Observable
package final class AppearancePreferences {
    @ObservationIgnored private let defaults: UserDefaults
    package var homeLayoutID: HomeLayoutID

    package init(
        defaults: UserDefaults,
        arguments: [String] = CommandLine.arguments
    ) {
        self.defaults = defaults
        let rawValue = Self.argumentValue(
            forKey: AppearancePreferenceKeys.homeLayoutID,
            arguments: arguments
        ) ?? defaults.string(forKey: AppearancePreferenceKeys.homeLayoutID)
        self.homeLayoutID = rawValue.flatMap(HomeLayoutID.init(rawValue:)) ?? .card
    }

    package func saveHomeLayoutID(_ homeLayoutID: HomeLayoutID) {
        guard self.homeLayoutID != homeLayoutID else { return }
        self.homeLayoutID = homeLayoutID
        defaults.set(homeLayoutID.rawValue, forKey: AppearancePreferenceKeys.homeLayoutID)
    }

    package static func argumentValue(
        forKey key: String,
        arguments: [String]
    ) -> String? {
        for index in arguments.indices {
            guard arguments[index] == "-\(key)" else { continue }
            let valueIndex = arguments.index(after: index)
            guard arguments.indices.contains(valueIndex) else { return nil }
            return arguments[valueIndex]
        }
        return nil
    }
}
