import Foundation
import VoidDisplayFoundation

package protocol SignalSessionHub: AnyObject, Sendable, DisplayShareFrameConsumer {
    nonisolated var activeClientCount: Int { get }
    nonisolated func addClient(
        _ connection: any SignalSocketConnection,
        target: ShareTarget,
        makeClientID: @escaping @Sendable () -> String,
        eventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) -> SignalSessionClientAddResult
    nonisolated func removeClient(_ connection: any SignalSocketConnection)
    nonisolated func sendRejection(reason: String, to connection: any SignalSocketConnection)
    nonisolated func disconnectAllClients()
    nonisolated func stopSharing()
    nonisolated func receiveSignalText(_ text: String, from connection: any SignalSocketConnection)
}
