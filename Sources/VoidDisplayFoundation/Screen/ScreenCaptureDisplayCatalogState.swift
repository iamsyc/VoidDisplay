import Foundation
import Observation
import ScreenCaptureKit
import CoreGraphics
package struct ScreenCaptureDisplayCatalogLoadErrorInfo: Equatable {
    package var domain: String
    package var code: Int
    package var description: String
    package var failureReason: String?
    package var recoverySuggestion: String?
}

package typealias ScreenCaptureDisplayCatalogState = ScreenCaptureCatalogStore
