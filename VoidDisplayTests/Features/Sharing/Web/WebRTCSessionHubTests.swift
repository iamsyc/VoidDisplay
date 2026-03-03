import Foundation
import Synchronization
import Testing
@testable import VoidDisplay

private final class MockSignalSocketConnection: SignalSocketConnection, Sendable {
    private struct State {
        var sentFrames: [Data] = []
        var cancelCallCount = 0
        var pendingCompletions: [@Sendable (Error?) -> Void] = []
    }

    private let state = Mutex(State())
    private let autoCompleteSends: Bool

    init(autoCompleteSends: Bool = true) {
        self.autoCompleteSends = autoCompleteSends
    }

    var sentFrames: [Data] {
        state.withLock { $0.sentFrames }
    }

    var cancelCallCount: Int {
        state.withLock { $0.cancelCallCount }
    }

    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        state.withLock { $0.sentFrames.append(content) }
        if autoCompleteSends {
            completion(nil)
            return
        }
        state.withLock { $0.pendingCompletions.append(completion) }
    }

    nonisolated func cancelSocket() {
        state.withLock { $0.cancelCallCount += 1 }
    }

    func decodedTextPayloads() -> [String] {
        sentFrames.compactMap { frame in
            let decoder = WebSocketFrameDecoder(
                maxFramePayloadBytes: Int.max,
                maxContinuationPayloadBytes: Int.max
            )
            let output = decoder.ingest(frame)
            guard let first = output.frames.first,
                  case .text(let text) = first else {
                return nil
            }
            return text
        }
    }

    @discardableResult
    func completeNextSend(error: Error? = nil) -> Bool {
        let completion = state.withLock { state -> (@Sendable (Error?) -> Void)? in
            guard !state.pendingCompletions.isEmpty else { return nil }
            return state.pendingCompletions.removeFirst()
        }
        completion?(error)
        return completion != nil
    }
}

private final class Counter: @unchecked Sendable {
    private let state = Mutex(0)

    nonisolated func increment() {
        state.withLock { $0 += 1 }
    }

    func value() -> Int {
        state.withLock { $0 }
    }
}

private final class MockPeerSession: @unchecked Sendable, WebRTCPeerSessioning {
    private let closeCalls: Counter

    init(closeCalls: Counter) {
        self.closeCalls = closeCalls
    }

    nonisolated func handleRemoteOffer(sdp: String) {
        _ = sdp
    }

    nonisolated func addRemoteCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        _ = sdp
        _ = sdpMid
        _ = sdpMLineIndex
    }

    nonisolated func close() {
        closeCalls.increment()
    }
}

private final class PeerFactoryBox: @unchecked Sendable {
    nonisolated(unsafe) weak var hub: WebRTCSessionHub?
    nonisolated(unsafe) weak var client: MockSignalSocketConnection?
    let closeCalls: Counter

    init(closeCalls: Counter) {
        self.closeCalls = closeCalls
    }

    func make(callbacks: WebRTCSessionHub.PeerCallbacks) -> (any WebRTCPeerSessioning)? {
        _ = callbacks
        if let hub, let client {
            hub.removeClient(client)
        }
        return MockPeerSession(closeCalls: closeCalls)
    }
}

struct WebRTCSessionHubTests {
    @MainActor @Test func addClientSendsReadySignal() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection()

        hub.addClient(client)

        let payloads = client.decodedTextPayloads()
        #expect(payloads.contains(where: { $0.contains(#""type":"ready""#) }))
        #expect(payloads.allSatisfy { !$0.contains(#""version""#) })
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
        let client = MockSignalSocketConnection(autoCompleteSends: false)
        hub.addClient(client)
        #expect(client.completeNextSend())

        hub.stopSharing()

        #expect(client.decodedTextPayloads().contains(where: { $0.contains(#""type":"stopped""#) }))
        #expect(client.cancelCallCount == 0)
        #expect(client.completeNextSend())
        #expect(client.cancelCallCount >= 1)
    }

    @MainActor @Test func viewerReadyDoesNotEmitErrorResponse() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection()
        hub.addClient(client)
        let baselinePayloadCount = client.decodedTextPayloads().count

        hub.receiveSignalText(#"{"type":"viewer_ready"}"#, from: client)

        let payloads = client.decodedTextPayloads()
        #expect(payloads.count == baselinePayloadCount)
    }

    @MainActor @Test func queuedSignalingMessagesPreserveOrderUnderBackpressure() throws {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection(autoCompleteSends: false)
        hub.addClient(client)
        #expect(client.completeNextSend())

        hub.receiveSignalText("not-a-json", from: client)
        hub.receiveSignalText("{}", from: client)
        hub.receiveSignalText(#"{"type":"unsupported"}"#, from: client)

        #expect(client.completeNextSend())
        #expect(client.completeNextSend())
        #expect(client.completeNextSend())

        let payloads = client.decodedTextPayloads()
        let invalidIndex = try #require(payloads.firstIndex(where: { $0.contains(#""reason":"invalid_signal_payload""#) }))
        let missingTypeIndex = try #require(payloads.firstIndex(where: { $0.contains(#""reason":"missing_signal_type""#) }))
        let unsupportedIndex = try #require(payloads.firstIndex(where: { $0.contains(#""reason":"unsupported_signal_type""#) }))

        #expect(invalidIndex < missingTypeIndex)
        #expect(missingTypeIndex < unsupportedIndex)
    }

    @MainActor @Test func removedClient_offer_doesNotCreatePeer() {
        let peerCreateCalls = Counter()
        let peerCloseCalls = Counter()
        let hub = WebRTCSessionHub(peerFactory: { _ in
            peerCreateCalls.increment()
            return MockPeerSession(closeCalls: peerCloseCalls)
        })
        let client = MockSignalSocketConnection()
        hub.addClient(client)
        hub.removeClient(client)

        hub.receiveSignalText(#"{"type":"offer","sdp":"v=0"}"#, from: client)

        #expect(peerCreateCalls.value() == 0)
        #expect(peerCloseCalls.value() == 0)
    }

#if canImport(WebRTC)
    @MainActor @Test func clientRemovedDuringEnsurePeer_closesNewPeer() {
        let peerCloseCalls = Counter()
        let box = PeerFactoryBox(closeCalls: peerCloseCalls)
        let hub = WebRTCSessionHub(peerFactory: { callbacks in
            box.make(callbacks: callbacks)
        })
        let client = MockSignalSocketConnection()
        box.hub = hub
        box.client = client
        hub.addClient(client)

        hub.receiveSignalText(#"{"type":"offer","sdp":"v=0"}"#, from: client)

        #expect(peerCloseCalls.value() == 1)
        #expect(hub.activeClientCount == 0)
    }
#endif
}
