import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreMedia
import Foundation
import Synchronization

private struct SendableSampleBuffer: @unchecked Sendable {
    nonisolated(unsafe) let value: CMSampleBuffer
}

private final class PreviewSinkMailbox: @unchecked Sendable {
    private struct State {
        var latestFrame: SendableSampleBuffer?
        var isDraining = false
        var isActive = true
    }

    private let sink: any DisplayPreviewSink
    private let state = Mutex(State())
    nonisolated init(sink: any DisplayPreviewSink) {
        self.sink = sink
    }

    nonisolated func submit(_ sampleBuffer: CMSampleBuffer) {
        let sample = SendableSampleBuffer(value: sampleBuffer)
        let shouldStartDraining = state.withLock { state -> Bool in
            guard state.isActive else { return false }
            state.latestFrame = sample
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldStartDraining else { return }

        Task.detached { [weak self] in
            self?.drain()
        }
    }

    nonisolated func deactivate() {
        state.withLock { state in
            state.isActive = false
            state.latestFrame = nil
            if !state.isDraining {
                state.isDraining = false
            }
        }
    }

    nonisolated private func drain() {
        while true {
            let nextFrame = state.withLock { state -> SendableSampleBuffer? in
                guard state.isActive else {
                    state.latestFrame = nil
                    state.isDraining = false
                    return nil
                }
                guard let latestFrame = state.latestFrame else {
                    state.isDraining = false
                    return nil
                }
                state.latestFrame = nil
                return latestFrame
            }
            guard let nextFrame else { return }
            sink.submitFrame(nextFrame.value)
        }
    }
}
package final class DisplaySampleFanout: Sendable {
    private let mailboxes = Mutex<[ObjectIdentifier: PreviewSinkMailbox]>([:])

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        let key = ObjectIdentifier(sink as AnyObject)
        mailboxes.withLock { mailboxes in
            guard mailboxes[key] == nil else { return }
            let mailbox = PreviewSinkMailbox(sink: sink)
            mailboxes[key] = mailbox
        }
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        let mailbox = mailboxes.withLock {
            $0.removeValue(forKey: ObjectIdentifier(sink as AnyObject))
        }
        mailbox?.deactivate()
    }

    nonisolated func publishPreviewFrame(_ sampleBuffer: CMSampleBuffer) {
        let snapshot = mailboxes.withLock { Array($0.values) }
        for mailbox in snapshot {
            mailbox.submit(sampleBuffer)
        }
    }
}
