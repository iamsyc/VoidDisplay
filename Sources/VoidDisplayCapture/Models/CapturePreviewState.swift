import Foundation

package nonisolated enum CapturePreviewState: Equatable, Hashable, Sendable {
    case active
    case restarting
    case failed(failureCode: String)
    case released
}
