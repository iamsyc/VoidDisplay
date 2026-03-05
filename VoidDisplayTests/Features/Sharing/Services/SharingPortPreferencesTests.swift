import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct SharingPortPreferencesTests {
    @Test
    func defaultsTo8089WhenNoPreferenceExists() {
        let defaults = UserDefaults(suiteName: "SharingPortPreferencesTests.defaults")!
        defaults.removePersistentDomain(forName: "SharingPortPreferencesTests.defaults")
        let sut = SharingPortPreferences(defaults: defaults)

        #expect(sut.preferredPort == 8089)
    }

    @Test
    func savePreferredPortPersistsValue() {
        let defaults = UserDefaults(suiteName: "SharingPortPreferencesTests.persist")!
        defaults.removePersistentDomain(forName: "SharingPortPreferencesTests.persist")
        let sut = SharingPortPreferences(defaults: defaults)

        sut.savePreferredPort(9090)

        #expect(sut.preferredPort == 9090)
    }

    @Test
    func argumentDomainPreferredPortOverridesPersistentValue() {
        let suiteName = "SharingPortPreferencesTests.args.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        }

        defaults.set(19090, forKey: SharingPortPreferenceKeys.preferredPort)
        defaults.setVolatileDomain(
            [SharingPortPreferenceKeys.preferredPort: 20001],
            forName: UserDefaults.argumentDomain
        )

        let sut = SharingPortPreferences(defaults: defaults)
        #expect(sut.preferredPort == 20001)
    }

}
