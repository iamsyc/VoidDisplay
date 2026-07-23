import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import CoreVideo
import Synchronization
package final class DisplayPreviewSubscription: Sendable {
    package let displayID: CGDirectDisplayID
    package let resolutionText: String

    private let session: any DisplayCaptureSessioning
    private let onAttachedPreviewSinkCountChanged: @Sendable (Int) -> Void
    private let setShowsCursorClosure: @Sendable (Bool) async throws -> Void
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)
    private let attachedSinks = Mutex<[ObjectIdentifier: WeakSink]>([:])

    private final class WeakSink: @unchecked Sendable {
        nonisolated(unsafe) weak var value: (any DisplayPreviewSink)?

        nonisolated init(_ value: any DisplayPreviewSink) {
            self.value = value
        }
    }

    package nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning,
        cancelClosure: @escaping @Sendable () -> Void,
        onAttachedPreviewSinkCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
        setShowsCursorClosure: @escaping @Sendable (Bool) async throws -> Void = { _ in }
    ) {
        self.displayID = displayID
        self.resolutionText = resolutionText
        self.session = session
        self.onAttachedPreviewSinkCountChanged = onAttachedPreviewSinkCountChanged
        self.setShowsCursorClosure = setShowsCursorClosure
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        let shouldAttach = attachedSinks.withLock { attachedSinks -> Bool in
            let key = ObjectIdentifier(sink as AnyObject)
            if let existing = attachedSinks[key], existing.value != nil {
                return false
            }
            attachedSinks[key] = WeakSink(sink)
            return true
        }
        guard shouldAttach else { return }
        session.attachPreviewSink(sink)
        onAttachedPreviewSinkCountChanged(1)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        let shouldDetach = attachedSinks.withLock { attachedSinks -> Bool in
            let key = ObjectIdentifier(sink as AnyObject)
            guard let removed = attachedSinks.removeValue(forKey: key) else {
                return false
            }
            return removed.value != nil
        }
        guard shouldDetach else { return }
        session.detachPreviewSink(sink)
        onAttachedPreviewSinkCountChanged(-1)
    }

    nonisolated func cancel() {
        let session = self.session
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        guard let closure else { return }

        let sinksToDetach: [any DisplayPreviewSink] = attachedSinks.withLock { dict in
            let snapshot = dict.values.compactMap(\.value)
            dict.removeAll(keepingCapacity: true)
            return snapshot
        }
        for sink in sinksToDetach {
            session.detachPreviewSink(sink)
            onAttachedPreviewSinkCountChanged(-1)
        }

        closure()
    }

    package nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot {
        session.captureMetricsSnapshot()
    }

    nonisolated func setShowsCursor(_ showsCursor: Bool) async throws {
        try await setShowsCursorClosure(showsCursor)
    }

    deinit { cancel() }
}
