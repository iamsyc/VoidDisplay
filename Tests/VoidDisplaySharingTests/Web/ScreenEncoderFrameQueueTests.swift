import Testing
@testable import VoidDisplaySharing

struct ScreenEncoderFrameQueueTests {
    @Test(arguments: [1, 2]) func completionResumesLastInputWithoutNewInput(capacity: Int) throws {
        var queue = ScreenEncoderFrameQueue<Int>(capacity: capacity)
        queue.start()
        let firstValue = queue.enqueue(1, keyframe: false)
        let first = try #require(firstValue)
        if capacity == 2 { #expect(queue.enqueue(2, keyframe: false) != nil) }
        #expect(queue.enqueue(3, keyframe: true) == nil)
        #expect(queue.enqueue(4, keyframe: false) == nil)
        #expect(queue.diagnostics.pendingFrames == 1)
        #expect(queue.diagnostics.capacityDrops == 1)
        #expect(queue.complete(first.id, as: .output)?.frame == 1)
        let recoveredValue = queue.takePending()
        let recovered = try #require(recoveredValue)
        #expect(recovered.frame == 4)
        #expect(recovered.keyframe)
        #expect(queue.diagnostics.resumedFrames == 1)
        #expect(queue.diagnostics.inFlightFrames == capacity)
        #expect(queue.diagnostics.pendingFrames == 0)
        #expect(queue.takePending() == nil)
    }

    @Test func replacementAndCompletionCannotReorderSubmissions() throws {
        var queue = ScreenEncoderFrameQueue<Int>(capacity: 2)
        queue.start()
        let firstValue = queue.enqueue(1, keyframe: false)
        let first = try #require(firstValue)
        let secondValue = queue.enqueue(2, keyframe: false)
        let second = try #require(secondValue)
        #expect(queue.enqueue(3, keyframe: false) == nil)
        // Even if ingress runs between completion and draining, the newer
        // input replaces the pending image instead of leaving an older tail.
        queue.complete(first.id, as: .output)
        let fourthValue = queue.enqueue(4, keyframe: false)
        let fourth = try #require(fourthValue)
        #expect(fourth.frame == 4)
        #expect(fourth.id > second.id)
        #expect(queue.takePending() == nil)
        #expect(queue.diagnostics.capacityDrops == 1)
    }

    @Test(arguments: [ScreenEncoderFrameQueue<Int>.Completion.compressionFailure, .hardwareDrop, .outputFailure])
    func failedKeyframeKeepsRequestButNeverRetriesIt(outcome: ScreenEncoderFrameQueue<Int>.Completion) throws {
        var queue = ScreenEncoderFrameQueue<Int>(capacity: 1)
        queue.start()
        let firstValue = queue.enqueue(1, keyframe: true)
        let first = try #require(firstValue)
        #expect(queue.enqueue(2, keyframe: false) == nil)
        queue.complete(first.id, as: outcome)
        let secondValue = queue.takePending()
        let second = try #require(secondValue)
        #expect(second.frame == 2)
        #expect(second.keyframe)
        queue.complete(second.id, as: outcome)
        #expect(queue.takePending() == nil)
        #expect(queue.diagnostics.submittedFrames == 2)
        let thirdValue = queue.enqueue(3, keyframe: false)
        let third = try #require(thirdValue)
        #expect(third.keyframe)
    }

    @Test func synchronousFailureAndDuplicateCallbackHaveOneCompletion() throws {
        var queue = ScreenEncoderFrameQueue<Int>(capacity: 1)
        queue.start()
        let firstValue = queue.enqueue(1, keyframe: false)
        let first = try #require(firstValue)
        queue.complete(first.id, as: .compressionFailure)
        #expect(queue.complete(first.id, as: .compressionFailure) == nil)
        #expect(queue.complete(first.id, as: .output) == nil)
        #expect(queue.diagnostics.compressionFailures == 1)
        #expect(queue.diagnostics.outputFrames == 0)
        #expect(queue.diagnostics.inFlightFrames == 0)
    }

    @Test func stopClearsPendingAndRestartRejectsOldCallbacks() throws {
        var queue = ScreenEncoderFrameQueue<Int>(capacity: 1)
        queue.start()
        let firstValue = queue.enqueue(1, keyframe: true)
        let first = try #require(firstValue)
        #expect(queue.enqueue(2, keyframe: true) == nil)
        let oldGeneration = queue.generation
        queue.stop()
        #expect(queue.diagnostics.releasedFrames == 1)
        #expect(queue.diagnostics.releasedPendingFrames == 1)
        #expect(queue.takePending() == nil)
        #expect(queue.enqueue(3, keyframe: false) == nil)
        queue.stop()
        #expect(queue.diagnostics.releasedFrames == 1)
        queue.start()
        let newValue = queue.enqueue(4, keyframe: false)
        let new = try #require(newValue)
        #expect(new.id > first.id)
        #expect(!new.keyframe)
        #expect(queue.complete(first.id, as: .output) == nil)
        queue.callbackRejected(generation: oldGeneration)
        #expect(queue.diagnostics.callbackRejections == 0)
        #expect(queue.diagnostics.inFlightFrames == 1)
        #expect(queue.diagnostics.outputFrames == 0)
    }

    @Test func backpressureAndRestartKeepOwnedBuffersBounded() throws {
        final class Buffer {}
        var queue = ScreenEncoderFrameQueue<Buffer>(capacity: 2)
        queue.start()
        weak var first: Buffer?
        weak var replaced: Buffer?
        weak var latest: Buffer?
        do {
            let buffer = Buffer()
            first = buffer
            #expect(queue.enqueue(buffer, keyframe: false) != nil)
        }
        #expect(queue.enqueue(Buffer(), keyframe: false) != nil)
        for index in 0..<1_000 {
            let buffer = Buffer()
            if index == 0 { replaced = buffer }
            latest = buffer
            #expect(queue.enqueue(buffer, keyframe: false) == nil)
            #expect(queue.diagnostics.inFlightFrames == 2)
            #expect(queue.diagnostics.pendingFrames == 1)
        }
        #expect(first != nil)
        #expect(replaced == nil)
        #expect(latest != nil)
        #expect(queue.diagnostics.capacityDrops == 999)
        queue.stop()
        #expect(first == nil)
        #expect(latest == nil)
        #expect(queue.diagnostics.inFlightFrames == 0)
        #expect(queue.diagnostics.pendingFrames == 0)
    }

    @Test func stabilityRepeatedBackpressureAndRestartDrainsEveryGeneration() throws {
        var queue = ScreenEncoderFrameQueue<Int>(capacity: 2)
        for cycle in 0..<200 {
            queue.start()
            let firstValue = queue.enqueue(cycle * 3, keyframe: false)
            let first = try #require(firstValue)
            let secondValue = queue.enqueue(cycle * 3 + 1, keyframe: false)
            let second = try #require(secondValue)
            #expect(queue.enqueue(cycle * 3 + 2, keyframe: true) == nil)
            queue.complete(first.id, as: .output)
            let lastValue = queue.takePending()
            let last = try #require(lastValue)
            #expect(last.keyframe)
            queue.complete(second.id, as: .output)
            queue.complete(last.id, as: .output)
            #expect(queue.diagnostics.outputFrames == 3)
            queue.stop()
            #expect(queue.diagnostics.pendingFrames == 0)
            #expect(queue.diagnostics.inFlightFrames == 0)
        }
    }
}
