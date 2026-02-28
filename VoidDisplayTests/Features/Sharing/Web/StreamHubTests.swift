import Foundation
import Testing
@testable import VoidDisplay

@MainActor
private final class MockLiveSocketConnection: LiveSocketConnection {
    var sentPayloads: [Data] = []
    var cancelCallCount = 0
    var autoComplete = true
    private var pendingCompletions: [(@Sendable (Error?) -> Void)] = []

    func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        sentPayloads.append(content)
        if autoComplete {
            completion(nil)
            return
        }
        pendingCompletions.append(completion)
    }

    func cancelSocket() {
        cancelCallCount += 1
    }

    func completeNextSend(error: Error? = nil) {
        guard !pendingCompletions.isEmpty else { return }
        let completion = pendingCompletions.removeFirst()
        completion(error)
    }
}

struct StreamHubTests {

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
