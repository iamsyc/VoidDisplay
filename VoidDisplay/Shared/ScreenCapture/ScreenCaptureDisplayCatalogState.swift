import Foundation
import Observation
import ScreenCaptureKit
import CoreGraphics

struct ScreenCaptureDisplayCatalogLoadErrorInfo: Equatable {
    var domain: String
    var code: Int
    var description: String
    var failureReason: String?
    var recoverySuggestion: String?
}

typealias ScreenCaptureDisplayCatalogState = ScreenCaptureCatalogStore
