/// The encoder's serial executor owns this state. There are at most `capacity`
/// submitted frames and one replaceable pending frame; completion, not a timer,
/// advances the pending frame. IDs survive restarts so stale callbacks are inert.
package nonisolated struct ScreenEncoderFrameQueue<Frame> {
    package struct Submission {
        package let id: UInt
        package let frame: Frame
        package var keyframe: Bool
        fileprivate let deferred: Bool
    }

    package enum Completion {
        case output, compressionFailure, hardwareDrop, outputFailure
    }

    private let capacity: Int
    private var nextID: UInt = 0
    private var needsKeyframe = false
    private var active = false
    private var pending: Submission?
    private var submitted: [UInt: Submission] = [:]
    private var counts = ScreenEncoderDiagnostics()
    package private(set) var generation: UInt = 0

    package init(capacity: Int) {
        precondition((1...2).contains(capacity))
        self.capacity = capacity
    }

    package var diagnostics: ScreenEncoderDiagnostics {
        var snapshot = counts
        snapshot.inFlightFrames = submitted.count
        snapshot.pendingFrames = pending == nil ? 0 : 1
        return snapshot
    }

    package mutating func start() {
        stop()
        counts = ScreenEncoderDiagnostics()
        active = true
    }

    package mutating func stop() {
        generation += 1
        active = false
        counts.releasedFrames += submitted.count
        counts.releasedPendingFrames += pending == nil ? 0 : 1
        submitted.removeAll(keepingCapacity: true)
        pending = nil
        needsKeyframe = false
    }

    package mutating func inputFailed(keyframe: Bool = false) {
        counts.inputFrames += 1
        counts.inputFailures += 1
        needsKeyframe = needsKeyframe || keyframe
    }

    package mutating func enqueue(_ frame: Frame, keyframe: Bool) -> Submission? {
        guard active else { inputFailed(); return nil }
        counts.inputFrames += 1
        needsKeyframe = needsKeyframe || keyframe
        nextID += 1
        let deferred = submitted.count == capacity
        if deferred { counts.deferredFrames += 1 }
        if pending != nil { counts.capacityDrops += 1 }
        pending = Submission(id: nextID, frame: frame, keyframe: false, deferred: deferred)
        return takePending()
    }

    package mutating func takePending() -> Submission? {
        guard active, submitted.count < capacity, var next = pending else { return nil }
        pending = nil
        next.keyframe = needsKeyframe
        needsKeyframe = false
        submitted[next.id] = next
        counts.submittedFrames += 1
        if next.deferred { counts.resumedFrames += 1 }
        counts.peakInFlightFrames = max(counts.peakInFlightFrames, submitted.count)
        return next
    }

    package func submission(_ id: UInt) -> Submission? { submitted[id] }

    @discardableResult
    package mutating func complete(_ id: UInt, as outcome: Completion) -> Submission? {
        guard let completed = submitted.removeValue(forKey: id) else { return nil }
        switch outcome {
        case .output: counts.outputFrames += 1
        case .compressionFailure: counts.compressionFailures += 1
        case .hardwareDrop: counts.hardwareDrops += 1
        case .outputFailure: counts.outputFailures += 1
        }
        if outcome != .output { needsKeyframe = needsKeyframe || completed.keyframe }
        return completed
    }

    package mutating func callbackRejected(generation expected: UInt) {
        guard generation == expected else { return }
        counts.callbackRejections += 1
    }
}
