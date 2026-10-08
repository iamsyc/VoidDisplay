import Foundation
package struct DisplaySurfaceStatusItemPresentation: Identifiable, Equatable {
    package let id: String
    package let title: String
    package let value: String
    package let accessibilityIdentifier: String
    package let tone: DisplaySurfaceStatusTone
    package let isFailureCode: Bool

    package init(
        id: String,
        title: String,
        value: String,
        accessibilityIdentifier: String,
        tone: DisplaySurfaceStatusTone = .neutral,
        isFailureCode: Bool = false
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
        self.tone = tone
        self.isFailureCode = isFailureCode
    }
}

package enum DisplaySurfaceStatusTone: Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}
