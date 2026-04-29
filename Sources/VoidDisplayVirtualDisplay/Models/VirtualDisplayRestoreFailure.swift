import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package struct VirtualDisplayRestoreFailure: Identifiable, Equatable {
    package let id: UUID
    package let name: String
    package let serialNum: UInt32
    package let message: String

    package init(id: UUID, name: String, serialNum: UInt32, message: String) {
        self.id = id
        self.name = name
        self.serialNum = serialNum
        self.message = message
    }
}
