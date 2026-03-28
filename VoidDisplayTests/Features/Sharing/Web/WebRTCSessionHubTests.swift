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

private final class SharingEventRecorder: @unchecked Sendable {
    private let events = Mutex<[SharingSessionEvent]>([])

    nonisolated func record(_ event: SharingSessionEvent) {
        events.withLock { $0.append(event) }
    }

    func currentPhases() -> [SharingPeerPhase] {
        events.withLock { $0.map(\.recordedPhase) }
    }

    func currentSequences() -> [UInt64] {
        events.withLock { $0.map(\.recordedSequence) }
    }
}

private final class PeerCallbacksBox: @unchecked Sendable {
    nonisolated(unsafe) var callbacks: WebRTCSessionHub.PeerCallbacks?
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

        let result = hub.addClient(client, target: .main, eventSink: { _ in })

        #expect(isAccepted(result))
        let payloads = client.decodedTextPayloads()
        #expect(payloads.contains(where: { $0.contains(#""type":"ready""#) }))
        #expect(payloads.allSatisfy { !$0.contains(#""version""#) })
    }

    @MainActor @Test func malformedSignalPayloadReturnsError() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection()
        _ = hub.addClient(client, target: .main, eventSink: { _ in })

        hub.receiveSignalText("not-a-json", from: client)

        #expect(client.decodedTextPayloads().contains(where: { $0.contains(#""reason":"invalid_signal_payload""#) }))
    }

    @MainActor @Test func addClientRejectsViewerBeyondCapacity() {
        let hub = WebRTCSessionHub()
        var clients: [MockSignalSocketConnection] = []
        let idGenerationCount = Counter()

        for index in 0..<10 {
            let client = MockSignalSocketConnection()
            clients.append(client)
            let result = hub.addClient(
                client,
                target: .main,
                makeClientID: {
                    idGenerationCount.increment()
                    return "client-\(index)"
                },
                eventSink: { _ in }
            )
            #expect(isAccepted(result))
        }

        let acceptedIDGenerationCount = idGenerationCount.value()
        let rejectedClient = MockSignalSocketConnection()
        let result = hub.addClient(
            rejectedClient,
            target: .main,
            makeClientID: {
                idGenerationCount.increment()
                return "client-overflow"
            },
            eventSink: { _ in }
        )

        #expect(result == .rejected(reason: "too_many_viewers"))
        #expect(idGenerationCount.value() == acceptedIDGenerationCount)
        hub.sendRejection(reason: "too_many_viewers", to: rejectedClient)
        #expect(rejectedClient.decodedTextPayloads().contains(where: { $0.contains(#""reason":"too_many_viewers""#) }))
    }

    @MainActor @Test func stopSharingBroadcastsStoppedAndDisconnectsClients() {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection(autoCompleteSends: false)
        _ = hub.addClient(client, target: .main, eventSink: { _ in })
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
        _ = hub.addClient(client, target: .main, eventSink: { _ in })
        let baselinePayloadCount = client.decodedTextPayloads().count

        hub.receiveSignalText(#"{"type":"viewer_ready"}"#, from: client)

        let payloads = client.decodedTextPayloads()
        #expect(payloads.count == baselinePayloadCount)
    }

    @MainActor @Test func queuedSignalingMessagesPreserveOrderUnderBackpressure() throws {
        let hub = WebRTCSessionHub()
        let client = MockSignalSocketConnection(autoCompleteSends: false)
        _ = hub.addClient(client, target: .main, eventSink: { _ in })
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
        _ = hub.addClient(client, target: .main, eventSink: { _ in })
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
        _ = hub.addClient(client, target: .main, eventSink: { _ in })

        hub.receiveSignalText(#"{"type":"offer","sdp":"v=0"}"#, from: client)

        #expect(peerCloseCalls.value() == 1)
        #expect(hub.activeClientCount == 0)
    }

    @MainActor @Test func peerFailureClosesClientWithoutTerminalErrorSignal() {
        let callbacksBox = PeerCallbacksBox()
        let hub = WebRTCSessionHub(peerFactory: { callbacks in
            callbacksBox.callbacks = callbacks
            return MockPeerSession(closeCalls: Counter())
        })
        let client = MockSignalSocketConnection()
        _ = hub.addClient(client, target: .main, eventSink: { _ in })

        hub.receiveSignalText(#"{"type":"offer","sdp":"v=0"}"#, from: client)
        callbacksBox.callbacks?.onFailure("transient_peer_failure")

        let payloads = client.decodedTextPayloads()
        #expect(payloads.contains(where: { $0.contains(#""type":"ready""#) }))
        #expect(payloads.contains(where: { $0.contains(#""type":"error""#) }) == false)
        #expect(client.cancelCallCount == 1)
        #expect(hub.activeClientCount == 0)
    }

    @MainActor @Test func lifecycleEventsReflectOfferConnectAndClose() async {
        let eventRecorder = SharingEventRecorder()
        let callbacksBox = PeerCallbacksBox()
        let hub = WebRTCSessionHub(peerFactory: { callbacks in
            callbacksBox.callbacks = callbacks
            return MockPeerSession(closeCalls: Counter())
        })
        let client = MockSignalSocketConnection()

        let addResult = hub.addClient(
            client,
            target: .id(9),
            eventSink: { event in
                eventRecorder.record(event)
            }
        )
        #expect(isAccepted(addResult))

        hub.receiveSignalText(#"{"type":"offer","sdp":"v=0"}"#, from: client)
        callbacksBox.callbacks?.onConnected()
        callbacksBox.callbacks?.onDisconnected()

        let observed = await waitUntilPhases(eventRecorder, count: 5)
        #expect(observed)
        let phases = eventRecorder.currentPhases()
        #expect(phases == [
            .signalingConnected,
            .offerReceived,
            .peerConnected,
            .peerDisconnected,
            .closed,
        ])
        let sequences = eventRecorder.currentSequences()
        #expect(sequences == [1, 2, 3, 4, 5])
    }
#endif
}

private func isAccepted(_ result: WebRTCSessionHub.AddClientResult) -> Bool {
    if case .accepted = result {
        return true
    }
    return false
}

private func waitUntilPhases(
    _ recorder: SharingEventRecorder,
    count: Int,
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if recorder.currentPhases().count >= count {
            return true
        }
        await Task.yield()
    }
    return recorder.currentPhases().count >= count
}
