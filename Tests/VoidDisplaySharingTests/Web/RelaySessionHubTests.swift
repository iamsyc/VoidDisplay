@testable import VoidDisplayFoundation
@testable import VoidDisplaySharing
import CoreVideo
import Foundation
import Synchronization
import Testing

private final class RelayTestSocketConnection: SignalSocketConnection, Sendable {
    private struct State {
        var sentFrames: [Data] = []
        var cancelCallCount = 0
    }

    private let state = Mutex(State())

    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        state.withLock { $0.sentFrames.append(content) }
        completion(nil)
    }

    nonisolated func cancelSocket() {
        state.withLock { $0.cancelCallCount += 1 }
    }

    var cancelCallCount: Int {
        state.withLock { $0.cancelCallCount }
    }

    func decodedTextPayloads() -> [String] {
        state.withLock { $0.sentFrames }.compactMap { frame in
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
}

private final class FakeRelayClient: RelayHTTPClienting, @unchecked Sendable {
    private struct State {
        var publisherOffers: [(roomID: String, sdp: String)] = []
        var viewerOffers: [(roomID: String, clientID: String, sdp: String)] = []
        var publisherCandidates: [(roomID: String, publisherID: String, candidate: String)] = []
        var viewerCandidates: [(roomID: String, clientID: String, candidate: String)] = []
        var removedViewers: [(roomID: String, clientID: String)] = []
        var stoppedPublishers: [(roomID: String, publisherID: String)] = []
    }

    private let state = Mutex(State())
    private let onViewerOffer: (@Sendable () async -> Void)?
    private let onViewerCandidate: (@Sendable () async -> Void)?

    init(
        onViewerOffer: (@Sendable () async -> Void)? = nil,
        onViewerCandidate: (@Sendable () async -> Void)? = nil
    ) {
        self.onViewerOffer = onViewerOffer
        self.onViewerCandidate = onViewerCandidate
    }

    nonisolated func publisherOffer(roomID: String, sdp: String) async throws -> RelayPublisherOfferResponse {
        state.withLock { $0.publisherOffers.append((roomID, sdp)) }
        return RelayPublisherOfferResponse(sdp: "relay-publisher-answer", publisherID: "publisher-1")
    }

    nonisolated func publisherCandidate(
        roomID: String,
        publisherID: String,
        candidate: String,
        sdpMid _: String?,
        sdpMLineIndex _: Int32
    ) async throws {
        state.withLock { $0.publisherCandidates.append((roomID, publisherID, candidate)) }
    }

    nonisolated func viewerOffer(roomID: String, clientID: String, sdp: String) async throws -> String {
        state.withLock { $0.viewerOffers.append((roomID, clientID, sdp)) }
        await onViewerOffer?()
        return "relay-viewer-answer-\(clientID)"
    }

    nonisolated func viewerCandidate(
        roomID: String,
        clientID: String,
        candidate: String,
        sdpMid _: String?,
        sdpMLineIndex _: Int32
    ) async throws {
        state.withLock { $0.viewerCandidates.append((roomID, clientID, candidate)) }
        await onViewerCandidate?()
    }

    nonisolated func removeViewer(roomID: String, clientID: String) async {
        state.withLock { $0.removedViewers.append((roomID, clientID)) }
    }

    nonisolated func stopPublisher(roomID: String, publisherID: String) async {
        state.withLock { $0.stoppedPublishers.append((roomID, publisherID)) }
    }

    func viewerOffers() -> [(roomID: String, clientID: String, sdp: String)] {
        state.withLock { $0.viewerOffers }
    }

    func viewerCandidates() -> [(roomID: String, clientID: String, candidate: String)] {
        state.withLock { $0.viewerCandidates }
    }

    func removedViewers() -> [(roomID: String, clientID: String)] {
        state.withLock { $0.removedViewers }
    }

    func stoppedPublishers() -> [(roomID: String, publisherID: String)] {
        state.withLock { $0.stoppedPublishers }
    }
}

private final class FakePublisherSession: RelayPublisherSessioning, @unchecked Sendable {
    private struct State {
        var startCallCount = 0
        var closeCallCount = 0
        var profiles: [WebRTCStreamingProfile] = []
    }

    private let state = Mutex(State())
    private let onStart: (@Sendable () async throws -> Void)?
    private let onUpdate: (@Sendable (WebRTCStreamingProfile) -> Void)?

    init(
        onStart: (@Sendable () async throws -> Void)? = nil,
        onUpdate: (@Sendable (WebRTCStreamingProfile) -> Void)? = nil
    ) {
        self.onStart = onStart
        self.onUpdate = onUpdate
    }

    nonisolated func start() async throws {
        try await onStart?()
        state.withLock { $0.startCallCount += 1 }
    }

    nonisolated func updateEncodingProfile(_ profile: WebRTCStreamingProfile) {
        onUpdate?(profile)
        state.withLock { $0.profiles.append(profile) }
    }

    nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}

    nonisolated func close() {
        state.withLock { $0.closeCallCount += 1 }
    }

    func startCallCount() -> Int {
        state.withLock { $0.startCallCount }
    }

    func closeCallCount() -> Int {
        state.withLock { $0.closeCallCount }
    }

    func profiles() -> [WebRTCStreamingProfile] {
        state.withLock { $0.profiles }
    }
}

private final class PublisherFactoryRecorder: @unchecked Sendable {
    private let state = Mutex([(roomID: String, profile: WebRTCStreamingProfile, publisher: FakePublisherSession)]())

    func make(
        roomID: String,
        relayClient _: any RelayHTTPClienting,
        profile: WebRTCStreamingProfile
    ) -> (any RelayPublisherSessioning)? {
        let publisher = FakePublisherSession()
        state.withLock { $0.append((roomID, profile, publisher)) }
        return publisher
    }

    func records() -> [(roomID: String, profile: WebRTCStreamingProfile, publisher: FakePublisherSession)] {
        state.withLock { $0 }
    }
}

private final class RelayHubBox: @unchecked Sendable {
    private let state = Mutex<RelaySessionHub?>(nil)

    func set(_ hub: RelaySessionHub) {
        state.withLock { $0 = hub }
    }

    func activeClientCount() -> Int {
        state.withLock { $0 }?.activeClientCount ?? -1
    }

    func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        state.withLock { $0 }?.updatePerformanceMode(mode)
    }
}

private final class AsyncGate: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var isOpen = false
        var waitCallCount = 0
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state -> Bool in
                state.waitCallCount += 1
                guard !state.isOpen else { return true }
                state.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume(returning: ())
            }
        }
    }

    func open() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isOpen = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: ())
    }

    func waitCallCount() -> Int {
        state.withLock { $0.waitCallCount }
    }
}

private enum RelaySessionHubTestError: Error {
    case publisherStartFailed
}

struct RelaySessionHubTests {
    @MainActor @Test func firstViewerStartsDemandAndLastViewerClearsDemand() async {
        let client = FakeRelayClient()
        let factory = PublisherFactoryRecorder()
        let demandEvents = Mutex<[Bool]>([])
        let hub = RelaySessionHub(
            onDemandChanged: { value in demandEvents.withLock { $0.append(value) } },
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        let first = RelayTestSocketConnection()
        let second = RelayTestSocketConnection()

        #expect(isRelayAccepted(hub.addClient(first, target: .id(2), makeClientID: { "first" }, eventSink: { _ in })))
        #expect(isRelayAccepted(hub.addClient(second, target: .id(2), makeClientID: { "second" }, eventSink: { _ in })))
        hub.removeClient(first)
        hub.removeClient(second)

        #expect(demandEvents.withLock { $0 } == [true, false])
        #expect(await waitUntil { factory.records().first?.publisher.closeCallCount() == 1 })
    }

    @MainActor @Test func viewerSignalIsForwardedToRelayAndAnswerReturnsToBrowser() async throws {
        let client = FakeRelayClient()
        let factory = PublisherFactoryRecorder()
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        let socket = RelayTestSocketConnection()
        #expect(isRelayAccepted(hub.addClient(socket, target: .id(2), makeClientID: { "viewer-1" }, eventSink: { _ in })))

        hub.receiveSignalText(#"{"type":"offer","sdp":"viewer-offer"}"#, from: socket)

        #expect(await waitUntil { client.viewerOffers().count == 1 })
        #expect(client.viewerOffers().first?.roomID == "2")
        #expect(client.viewerOffers().first?.clientID == "viewer-1")
        #expect(client.viewerOffers().first?.sdp == "viewer-offer")
        let answer = try #require(socket.decodedTextPayloads().first(where: { $0.contains(#""type":"answer""#) }))
        #expect(answer.contains(#""sdp":"relay-viewer-answer-viewer-1""#))
    }

    @MainActor @Test func staleViewerOfferCleansRelayViewerAndDoesNotSendAnswer() async {
        let offerGate = AsyncGate()
        let client = FakeRelayClient(onViewerOffer: {
            await offerGate.wait()
        })
        let factory = PublisherFactoryRecorder()
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        let socket = RelayTestSocketConnection()
        #expect(isRelayAccepted(hub.addClient(socket, target: .id(2), makeClientID: { "viewer-1" }, eventSink: { _ in })))

        hub.receiveSignalText(#"{"type":"offer","sdp":"viewer-offer"}"#, from: socket)
        #expect(await waitUntil { client.viewerOffers().count == 1 })
        hub.removeClient(socket)
        offerGate.open()

        #expect(await waitUntil { client.removedViewers().count >= 2 })
        #expect(socket.decodedTextPayloads().contains(where: { $0.contains(#""type":"answer""#) }) == false)
    }

    @MainActor @Test func tenViewersCreateOnePublisherSession() async {
        let client = FakeRelayClient()
        let factory = PublisherFactoryRecorder()
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        for index in 0..<10 {
            let socket = RelayTestSocketConnection()
            #expect(isRelayAccepted(hub.addClient(
                socket,
                target: .id(2),
                makeClientID: { "viewer-\(index)" },
                eventSink: { _ in }
            )))
        }

        #expect(await waitUntil { factory.records().count == 1 })
        #expect(factory.records().first?.roomID == "2")
        #expect(factory.records().first?.profile == WebRTCStreamingProfile(performanceMode: .automatic))
    }

    @MainActor @Test func performanceModeChangeUpdatesOnlyPublisherProfile() async {
        let client = FakeRelayClient()
        let factory = PublisherFactoryRecorder()
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        let socket = RelayTestSocketConnection()
        #expect(isRelayAccepted(hub.addClient(socket, target: .id(2), makeClientID: { "viewer-1" }, eventSink: { _ in })))
        #expect(await waitUntil { factory.records().count == 1 })

        hub.updatePerformanceMode(.powerEfficient)

        let publisher = factory.records().first?.publisher
        #expect(publisher?.profiles().contains(WebRTCStreamingProfile(performanceMode: .powerEfficient)) == true)
        #expect(factory.records().count == 1)
    }

    @MainActor @Test func publisherStartupRefreshesProfileOutsideStateLock() async {
        let client = FakeRelayClient()
        let hubBox = RelayHubBox()
        let publisher = FakePublisherSession(
            onStart: {
                hubBox.updatePerformanceMode(.powerEfficient)
            },
            onUpdate: { _ in
                _ = hubBox.activeClientCount()
            }
        )
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: { _, _, _ in publisher }
        )
        hubBox.set(hub)
        let socket = RelayTestSocketConnection()

        #expect(isRelayAccepted(hub.addClient(socket, target: .id(2), makeClientID: { "viewer-1" }, eventSink: { _ in })))

        let powerEfficientProfile = WebRTCStreamingProfile(performanceMode: .powerEfficient)
        #expect(await waitUntil { publisher.profiles().contains(powerEfficientProfile) })
        #expect(publisher.startCallCount() == 1)
    }

    @MainActor @Test func stalePublisherStartupFailureDoesNotRemoveNewViewer() async {
        let client = FakeRelayClient()
        let firstStartGate = AsyncGate()
        let firstPublisher = FakePublisherSession(onStart: {
            await firstStartGate.wait()
            throw RelaySessionHubTestError.publisherStartFailed
        })
        let secondPublisher = FakePublisherSession()
        let factoryCalls = Mutex(0)
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: { _, _, _ in
                factoryCalls.withLock { calls -> any RelayPublisherSessioning in
                    calls += 1
                    return calls == 1 ? firstPublisher : secondPublisher
                }
            }
        )
        let staleSocket = RelayTestSocketConnection()
        let currentSocket = RelayTestSocketConnection()

        #expect(isRelayAccepted(hub.addClient(
            staleSocket,
            target: .id(2),
            makeClientID: { "stale-viewer" },
            eventSink: { _ in }
        )))
        #expect(await waitUntil { firstStartGate.waitCallCount() == 1 })
        hub.removeClient(staleSocket)
        #expect(isRelayAccepted(hub.addClient(
            currentSocket,
            target: .id(2),
            makeClientID: { "current-viewer" },
            eventSink: { _ in }
        )))
        #expect(await waitUntil { secondPublisher.startCallCount() == 1 })

        firstStartGate.open()

        #expect(await waitUntil { hub.activeClientCount == 1 })
        #expect(currentSocket.cancelCallCount == 0)
        #expect(staleSocket.cancelCallCount == 0)
    }

    @MainActor @Test func viewerIceCandidateIsForwardedToRelay() async {
        let client = FakeRelayClient()
        let factory = PublisherFactoryRecorder()
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        let socket = RelayTestSocketConnection()
        #expect(isRelayAccepted(hub.addClient(socket, target: .id(2), makeClientID: { "viewer-1" }, eventSink: { _ in })))

        hub.receiveSignalText(#"{"type":"ice_candidate","candidate":"candidate:1","sdpMid":"0","sdpMLineIndex":0}"#, from: socket)

        #expect(await waitUntil { client.viewerCandidates().count == 1 })
        #expect(client.viewerCandidates().first?.roomID == "2")
        #expect(client.viewerCandidates().first?.clientID == "viewer-1")
        #expect(client.viewerCandidates().first?.candidate == "candidate:1")
    }

    @MainActor @Test func staleViewerCandidateCleansRelayViewer() async {
        let candidateGate = AsyncGate()
        let client = FakeRelayClient(onViewerCandidate: {
            await candidateGate.wait()
        })
        let factory = PublisherFactoryRecorder()
        let hub = RelaySessionHub(
            relayClientProvider: { client },
            publisherFactory: factory.make
        )
        let socket = RelayTestSocketConnection()
        #expect(isRelayAccepted(hub.addClient(socket, target: .id(2), makeClientID: { "viewer-1" }, eventSink: { _ in })))

        hub.receiveSignalText(#"{"type":"ice_candidate","candidate":"candidate:1","sdpMid":"0","sdpMLineIndex":0}"#, from: socket)
        #expect(await waitUntil { client.viewerCandidates().count == 1 })
        hub.removeClient(socket)
        candidateGate.open()

        #expect(await waitUntil { client.removedViewers().count >= 2 })
    }
}

private func isRelayAccepted(_ result: SignalSessionClientAddResult) -> Bool {
    if case .accepted = result {
        return true
    }
    return false
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}
