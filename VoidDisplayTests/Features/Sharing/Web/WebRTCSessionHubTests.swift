import Foundation
import Synchronization
import Testing
@testable import VoidDisplay

private final class MockSignalSocketConnection: SignalSocketConnection, Sendable {
    private struct State {
        var sentFrames: [Data] = []
        var cancelCallCount = 0
    }

    private let state = Mutex(State())

    var sentFrames: [Data] {
        state.withLock { $0.sentFrames }
    }

    var cancelCallCount: Int {
        state.withLock { $0.cancelCallCount }
    }

    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        state.withLock { $0.sentFrames.append(content) }
        completion(nil)
    }

    nonisolated func cancelSocket() {
        state.withLock { $0.cancelCallCount += 1 }
    }

    func decodedTextPayloads() -> [String] {
        sentFrames.compactMap { frame in
            let decoded = decodeWebSocketFrames(from: frame)
            guard let first = decoded.frames.first,
                  case .text(let text) = first else {
                return nil
            }
            return text
        }
    }
}

struct WebRTCSessionHubTests {
    @MainActor @Test func addClientSendsReadySignal() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection()

        hub.addClient(client)

        #expect(client.decodedTextPayloads().contains(where: { $0.contains(#""type":"ready""#) }))
    }

    @MainActor @Test func malformedSignalPayloadReturnsError() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection()
        hub.addClient(client)

        hub.receiveSignalText("not-a-json", from: client)

        #expect(client.decodedTextPayloads().contains(where: { $0.contains(#""reason":"invalid_signal_payload""#) }))
    }

    @MainActor @Test func stopSharingBroadcastsStoppedAndDisconnectsClients() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection()
        hub.addClient(client)

        hub.stopSharing()

        #expect(client.decodedTextPayloads().contains(where: { $0.contains(#""type":"stopped""#) }))
        #expect(client.cancelCallCount >= 1)
    }
}
