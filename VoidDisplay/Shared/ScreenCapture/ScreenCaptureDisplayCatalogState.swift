import Foundation
import Observation
import ScreenCaptureKit

struct ScreenCaptureDisplayCatalogLoadErrorInfo: Equatable {
    var domain: String
    var code: Int
    var description: String
    var failureReason: String?
    var recoverySuggestion: String?
}

@MainActor
@Observable
final class ScreenCaptureDisplayCatalogState {
    var displays: [SCDisplay]?
    var hasScreenCapturePermission: Bool?
    var lastPreflightPermission: Bool?
    var lastRequestPermission: Bool?
    var isLoadingDisplays = false
    var loadErrorMessage: String?
    var lastLoadError: ScreenCaptureDisplayCatalogLoadErrorInfo?
    var showDebugInfo = false
}
