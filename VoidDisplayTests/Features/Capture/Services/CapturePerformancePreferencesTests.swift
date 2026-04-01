import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct CapturePerformancePreferencesTests {
    @Test
    func defaultsToAutomaticWhenNoPreferenceExists() {
        let suiteName = "CapturePerformancePreferencesTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sut = CapturePerformancePreferences(defaults: defaults)

        #expect(sut.mode == .automatic)
    }

    @Test
    func saveModePersistsAcrossNewInstance() {
        let suiteName = "CapturePerformancePreferencesTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sut = CapturePerformancePreferences(defaults: defaults)
        sut.saveMode(.powerEfficient)

        let reloaded = CapturePerformancePreferences(defaults: defaults)
        #expect(reloaded.mode == .powerEfficient)
    }
}
