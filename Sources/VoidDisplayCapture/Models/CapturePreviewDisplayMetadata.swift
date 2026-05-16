import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package struct CapturePreviewDisplayMetadata: Equatable, Sendable {
    package let displayName: String
    package let resolutionText: String
    package let isVirtualDisplay: Bool

    package init(displayName: String, resolutionText: String, isVirtualDisplay: Bool) {
        self.displayName = displayName
        self.resolutionText = resolutionText
        self.isVirtualDisplay = isVirtualDisplay
    }
}
