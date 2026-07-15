@testable import VoidDisplayApp
@testable import VoidDisplayDesignSystem
import Foundation
import Testing

@MainActor
struct AppearancePreferencesTests {
    @Test func defaultsToClassicWhenNoPreferenceExists() {
        let suiteName = "AppearancePreferencesTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )

        #expect(sut.skinID == .classic)
    }

    @Test func saveSkinIDPersistsAcrossNewInstance() {
        let suiteName = "AppearancePreferencesTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )
        sut.saveSkinID(.dashboard)

        let reloaded = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )

        #expect(reloaded.skinID == .dashboard)
    }

    @Test func invalidStoredValueFallsBackToClassic() {
        let suiteName = "AppearancePreferencesTests.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown", forKey: AppearancePreferenceKeys.skinID)

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )

        #expect(sut.skinID == .classic)
    }

    @Test func launchArgumentOverridesStoredValue() {
        let suiteName = "AppearancePreferencesTests.arguments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppSkinID.classic.rawValue, forKey: AppearancePreferenceKeys.skinID)

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay", "-appearance.skinID", "compact"]
        )

        #expect(sut.skinID == .compact)
    }
}
