import VoidDisplayFoundation
import Foundation
package struct UserFacingAlertState: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let title: String
    package let message: String

    package init(
        id: UUID = UUID(),
        title: String,
        message: String
    ) {
        self.id = id
        self.title = title
        self.message = message
    }
}
