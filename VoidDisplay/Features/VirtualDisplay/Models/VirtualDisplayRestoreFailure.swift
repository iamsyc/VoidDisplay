import Foundation

struct VirtualDisplayRestoreFailure: Identifiable, Equatable {
    let id: UUID
    let name: String
    let serialNum: UInt32
    let message: String
}
