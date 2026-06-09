import Foundation
import Observation
import VoidDisplayDesignSystem

package enum AppearancePreferenceKeys {
    package static let skinID = "appearance.skinID"
}

@MainActor
@Observable
package final class AppearancePreferences {
    @ObservationIgnored private let defaults: UserDefaults
    package var skinID: AppSkinID

    package init(
        defaults: UserDefaults,
        arguments: [String] = CommandLine.arguments
    ) {
        self.defaults = defaults
        let rawValue = Self.argumentValue(
            forKey: AppearancePreferenceKeys.skinID,
            arguments: arguments
        ) ?? defaults.string(forKey: AppearancePreferenceKeys.skinID)
        self.skinID = rawValue.flatMap(AppSkinID.init(rawValue:)) ?? .classic
    }

    package func saveSkinID(_ skinID: AppSkinID) {
        guard self.skinID != skinID else { return }
        self.skinID = skinID
        defaults.set(skinID.rawValue, forKey: AppearancePreferenceKeys.skinID)
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
