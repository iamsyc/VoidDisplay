import Foundation
import Synchronization
import Testing
@testable import VoidDisplay

private final class MockLiveSocketConnection: LiveSocketConnection, Sendable {
    private struct State {
        var sentPayloads: [Data] = []
        var cancelCallCount = 0
        var autoComplete = true
        var pendingCompletions: [(@Sendable (Error?) -> Void)] = []
    }
    
    private let state = Mutex(State())

    var sentPayloads: [Data] { state.withLock { $0.sentPayloads } }
    var cancelCallCount: Int { state.withLock { $0.cancelCallCount } }
    var autoComplete: Bool {
        get { state.withLock { $0.autoComplete } }
        set { state.withLock { $0.autoComplete = newValue } }
    }

    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let shouldComplete = state.withLock { state -> Bool in
            state.sentPayloads.append(content)
            if state.autoComplete {
                return true
            } else {
                state.pendingCompletions.append(completion)
                return false
            }
        }
        if shouldComplete {
            completion(nil)
        }
    }

    nonisolated func cancelSocket() {
        state.withLock { $0.cancelCallCount += 1 }
    }

    func completeNextSend(error: Error? = nil) {
        let completion = state.withLock { state -> (@Sendable (Error?) -> Void)? in
            guard !state.pendingCompletions.isEmpty else { return nil }
            return state.pendingCompletions.removeFirst()
        }
        completion?(error)
    }
}

struct LiveSocketHubTests {

    @MainActor @Test func broadcastsConfigAndPacketsToConnectedClients() async {
        let hub = LiveSocketHub()
        let client = MockLiveSocketConnection()
        hub.addClient(client)
        hub.updateConfiguration(.init(codec: "avc1.640028", width: 1920, height: 1080, timescale: 1_000_000))

        hub.broadcast(
            packet: EncodedVideoPacket(
                ptsUs: 123,
                isKeyframe: true,
                width: 1920,
                height: 1080,
                payload: Data([0x00, 0x00, 0x00, 0x01])
            )
        )
        await Task.yield()

        #expect(client.sentPayloads.count == 1)
        #expect(client.sentPayloads[0].contains(Data("config".utf8)))
    }

    @MainActor @Test func slowClientKeepsOnlyLatestPendingPacket() async {
        let hub = LiveSocketHub()
        hub.updateConfiguration(.init(codec: "avc1.640028", width: 1920, height: 1080, timescale: 1_000_000))

        let slowClient = MockLiveSocketConnection()
        slowClient.autoComplete = false
        let fastClient = MockLiveSocketConnection()
        hub.addClient(slowClient)
        hub.addClient(fastClient)

        hub.broadcast(packet: .init(ptsUs: 1, isKeyframe: true, width: 1920, height: 1080, payload: Data([1])))
        hub.broadcast(packet: .init(ptsUs: 2, isKeyframe: false, width: 1920, height: 1080, payload: Data([2])))
        hub.broadcast(packet: .init(ptsUs: 3, isKeyframe: false, width: 1920, height: 1080, payload: Data([3])))
        await Task.yield()

        #expect(fastClient.sentPayloads.count == 3)
        #expect(slowClient.sentPayloads.count == 1)

        slowClient.completeNextSend()
        await Task.yield()

        #expect(slowClient.sentPayloads.count == 2)
    }
}
