import SwiftUI

package enum CapturePreviewScaleMode: Hashable, CaseIterable {
    case fit
    case native

    package var title: LocalizedStringResource {
        switch self {
        case .fit:
            "Fit"
        case .native:
            "1:1"
        }
    }
}
