import Foundation
import Testing
@testable import VoidDisplay

@MainActor
private final class MockStreamClientConnection: StreamClientConnection {
    var sentPayloads: [Data] = []
    var cancelCallCount = 0
    var autoComplete = true
    private var pendingCompletions: [(@Sendable (Error?) -> Void)] = []

    func sendFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        sentPayloads.append(content)
        if autoComplete {
            completion(nil)
            return
        }
        pendingCompletions.append(completion)
    }

    func cancelStream() {
        cancelCallCount += 1
    }

    func completeNextSend(error: Error? = nil) {
        guard !pendingCompletions.isEmpty else { return }
        let completion = pendingCompletions.removeFirst()
        completion(error)
    }
}

@MainActor
private final class MutableFrameSource: @unchecked Sendable {
    var frame: Data

    init(frame: Data) {
        self.frame = frame
    }
}

struct StreamHubTests {

    @MainActor @Test func broadcastsFramesToAllConnectedClients() async {
        let frameSource = MutableFrameSource(frame: Data("frame-1".utf8))
        let hub = StreamHub(
            isSharingProvider: { true },
            frameProvider: { frameSource.frame },
            automaticallyStartTimer: false,
            onSendError: { _ in }
        )

        let firstClient = MockStreamClientConnection()
        let secondClient = MockStreamClientConnection()
        hub.addClient(firstClient)
        hub.addClient(secondClient)

        hub.pumpOnceForTesting()
        await Task.yield()
        let firstExpected = makeMJPEGFramePayload(
            frame: frameSource.frame,
            boundary: WebRequestHandler.streamBoundary
        )
        #expect(firstClient.sentPayloads == [firstExpected])
        #expect(secondClient.sentPayloads == [firstExpected])

        frameSource.frame = Data("frame-2".utf8)
        hub.pumpOnceForTesting()
        await Task.yield()
        let secondExpected = makeMJPEGFramePayload(
            frame: frameSource.frame,
            boundary: WebRequestHandler.streamBoundary
        )
        #expect(firstClient.sentPayloads == [firstExpected, secondExpected])
        #expect(secondClient.sentPayloads == [firstExpected, secondExpected])
    }

    @MainActor @Test func slowClientDoesNotBlockOthersAndReceivesLatestPendingFrame() async {
        let frameSource = MutableFrameSource(frame: Data("A".utf8))
        let hub = StreamHub(
            isSharingProvider: { true },
            frameProvider: { frameSource.frame },
            automaticallyStartTimer: false,
            onSendError: { _ in }
        )

        let slowClient = MockStreamClientConnection()
        slowClient.autoComplete = false
        let fastClient = MockStreamClientConnection()
        hub.addClient(slowClient)
        hub.addClient(fastClient)

        hub.pumpOnceForTesting()
        await Task.yield()
        frameSource.frame = Data("B".utf8)
        hub.pumpOnceForTesting()
        await Task.yield()
        frameSource.frame = Data("C".utf8)
        hub.pumpOnceForTesting()
        await Task.yield()

        #expect(fastClient.sentPayloads.count == 3)
        #expect(slowClient.sentPayloads.count == 1)

        slowClient.completeNextSend()
        await Task.yield()

        #expect(slowClient.sentPayloads.count == 2)
        let latestExpected = makeMJPEGFramePayload(
            frame: Data("C".utf8),
            boundary: WebRequestHandler.streamBoundary
        )
        #expect(slowClient.sentPayloads[1] == latestExpected)
    }
}
