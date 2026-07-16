@testable import VoidDisplayApp
import Foundation
import Testing

@MainActor
struct AppearancePreferencesTests {
    @Test func defaultsToCardWhenNoPreferenceExists() {
        let suiteName = "AppearancePreferencesTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )

        #expect(sut.homeLayoutID == .card)
    }

    @Test func saveHomeLayoutIDPersistsAcrossNewInstance() {
        let suiteName = "AppearancePreferencesTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )
        sut.saveHomeLayoutID(.list)

        let reloaded = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )

        #expect(reloaded.homeLayoutID == .list)
    }

    @Test func invalidStoredValueFallsBackToCard() {
        let suiteName = "AppearancePreferencesTests.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown", forKey: AppearancePreferenceKeys.homeLayoutID)

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay"]
        )

        #expect(sut.homeLayoutID == .card)
    }

    @Test func launchArgumentOverridesStoredValue() {
        let suiteName = "AppearancePreferencesTests.arguments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(HomeLayoutID.card.rawValue, forKey: AppearancePreferenceKeys.homeLayoutID)

        let sut = AppearancePreferences(
            defaults: defaults,
            arguments: ["VoidDisplay", "-appearance.homeLayoutID", "list"]
        )

        #expect(sut.homeLayoutID == .list)
    }
}
