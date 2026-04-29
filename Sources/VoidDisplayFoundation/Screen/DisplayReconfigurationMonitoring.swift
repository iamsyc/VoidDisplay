import Foundation

@MainActor
package protocol DisplayReconfigurationMonitoring: AnyObject {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool
    func stop()
}
