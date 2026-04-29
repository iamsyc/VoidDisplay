import CoreGraphics
import CoreVideo
import Foundation
import Synchronization

package protocol DisplayShareFrameConsumer: AnyObject, Sendable {
    nonisolated var hasDemand: Bool { get }
    nonisolated func stopSharing()
    nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64)
}

package final class DisplayShareSubscription: Sendable {
    package let displayID: CGDirectDisplayID
    package let shareFrameConsumer: any DisplayShareFrameConsumer

    private let prepareForSharingClosure: @Sendable () async throws -> Void
    private let releasePreparedShareClosure: @Sendable () async -> Void
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)
    private let prepareRetainTask = Mutex<Task<Bool, Error>?>(nil)
    private let hasRetainedShareCursorOverride = Mutex(false)

    package nonisolated init(
        displayID: CGDirectDisplayID,
        shareFrameConsumer: any DisplayShareFrameConsumer,
        cancelClosure: @escaping @Sendable () -> Void,
        prepareForSharingClosure: @escaping @Sendable () async throws -> Void = {},
        releasePreparedShareClosure: @escaping @Sendable () async -> Void = {}
    ) {
        self.displayID = displayID
        self.shareFrameConsumer = shareFrameConsumer
        self.prepareForSharingClosure = prepareForSharingClosure
        self.releasePreparedShareClosure = releasePreparedShareClosure
        cancelState.withLock { $0 = cancelClosure }
    }

    package nonisolated func prepareForSharing() async throws {
        try await prepareForSharingClosure()
        hasRetainedShareCursorOverride.withLock { $0 = true }
    }

    package nonisolated func prepareForSharing(
        invalidationContext: DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<Void> {
        let retainTask = Task<Bool, Error> {
            try await prepareForSharingClosure()
            return true
        }
        prepareRetainTask.withLock { state in
            state = retainTask
        }
        do {
            let outcome = try await invalidationContext.race {
                _ = try await retainTask.value
            }
            switch outcome {
            case .started:
                prepareRetainTask.withLock { state in
                    state = nil
                }
                hasRetainedShareCursorOverride.withLock { $0 = true }
            case .invalidated:
                cancel()
            }
            return outcome
        } catch {
            cancel()
            throw error
        }
    }

    package nonisolated func cancel() {
        let pendingRetainTask = prepareRetainTask.withLock { state -> Task<Bool, Error>? in
            let current = state
            state = nil
            return current
        }
        let hasRetained = hasRetainedShareCursorOverride.withLock { state -> Bool in
            let current = state
            state = false
            return current
        }
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        guard let closure else { return }
        if let pendingRetainTask {
            Task.detached { [self] in
                var needsRelease = hasRetained
                do {
                    let didRetain = try await pendingRetainTask.value
                    needsRelease = needsRelease || didRetain
                } catch {
                }
                if needsRelease {
                    await releasePreparedShareClosure()
                }
                closure()
            }
            return
        }
        Task {
            if hasRetained {
                await releasePreparedShareClosure()
            }
            closure()
        }
    }

    deinit { cancel() }
}
