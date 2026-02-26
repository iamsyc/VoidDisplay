import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct SharingPortPreferencesTests {
    @Test
    func defaultsTo8081WhenNoPreferenceExists() {
        let defaults = UserDefaults(suiteName: "SharingPortPreferencesTests.defaults")!
        defaults.removePersistentDomain(forName: "SharingPortPreferencesTests.defaults")
        let sut = SharingPortPreferences(defaults: defaults)

        #expect(sut.preferredPort == 8081)
    }

    @Test
    func savePreferredPortPersistsValue() {
        let defaults = UserDefaults(suiteName: "SharingPortPreferencesTests.persist")!
        defaults.removePersistentDomain(forName: "SharingPortPreferencesTests.persist")
        let sut = SharingPortPreferences(defaults: defaults)

        sut.savePreferredPort(9090)

        #expect(sut.preferredPort == 9090)
    }
}
