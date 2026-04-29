import VoidDisplayFoundation
import Foundation
package protocol ObservabilitySnapshotProvider {
    associatedtype Snapshot: Codable & Sendable
    var key: String { get }
    @MainActor func makeSnapshot() -> Snapshot
}
