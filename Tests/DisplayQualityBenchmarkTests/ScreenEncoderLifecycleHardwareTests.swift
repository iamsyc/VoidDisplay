import CoreVideo
import Foundation
import Synchronization
import Testing
import VoidDisplaySharing
@preconcurrency import WebRTC

extension ScreenEncoderHardwareTests {
    @Test func callbackCanReadDiagnosticsStopAndRestartWithoutDeadlock() throws {
        let encoder = ScreenVideoEncoder()
        let buffer = try makeBuffer(width: 640, height: 360)
        let reentered = Mutex(false)
        let oldOutput = Mutex<[UInt32]>([])
        encoder.setCallback { [weak encoder] image, _ in
            guard let encoder else { return false }
            oldOutput.withLock { $0.append(image.timeStamp) }
            _ = encoder.diagnostics
            _ = encoder.release()
            encoder.setCallback(nil)
            let restarted = encoder.startEncode(with: settings(width: 640, height: 360), numberOfCores: 1) == 0
            reentered.withLock { $0 = restarted }
            return false
        }
        defer { _ = encoder.release(); encoder.setCallback(nil) }
        #expect(encoder.startEncode(with: settings(width: 640, height: 360), numberOfCores: 1) == 0)
        #expect(encoder.encode(frame(buffer, id: 1), codecSpecificInfo: nil, frameTypes: []) == 0)
        #expect(waitUntil { reentered.withLock { $0 } })
        #expect(encoder.diagnostics.outputFrames == 0)
        #expect(encoder.diagnostics.callbackRejections == 0)
        #expect(encoder.diagnostics.inFlightFrames == 0)
        #expect(encoder.diagnostics.pendingFrames == 0)
        #expect(oldOutput.withLock { $0 } == [1])
    }

    @Test func repeatedReleaseWithPendingWorkClearsEverySession() throws {
        let encoder = ScreenVideoEncoder(maximumInFlightFrames: 1)
        let buffer = try makeBuffer(width: 3840, height: 2160)
        defer { _ = encoder.release(); encoder.setCallback(nil) }
        for _ in 0..<20 {
            let stopped = Mutex<ScreenEncoderDiagnostics?>(nil)
            encoder.setCallback { [weak encoder] image, _ in
                guard image.timeStamp == 0, let encoder else { return false }
                for id in UInt32(1)...3 {
                    #expect(encoder.encode(frame(buffer, id: id), codecSpecificInfo: nil, frameTypes: []) == 0)
                }
                #expect(encoder.release() == 0)
                stopped.withLock { $0 = encoder.diagnostics }
                return false
            }
            #expect(encoder.startEncode(with: settings(width: 3840, height: 2160), numberOfCores: 1) == 0)
            #expect(encoder.encode(frame(buffer, id: 0), codecSpecificInfo: nil, frameTypes: []) == 0)
            #expect(waitUntil { stopped.withLock { $0 != nil } })
            let snapshot = try #require(stopped.withLock { $0 })
            #expect(snapshot.inFlightFrames == 0)
            #expect(snapshot.pendingFrames == 0)
            #expect(snapshot.releasedFrames == 1)
            #expect(snapshot.releasedPendingFrames == 1)
            #expect(snapshot.peakInFlightFrames <= 1)
            #expect(encoder.release() == 0)
            #expect(encoder.diagnostics == snapshot)
        }
    }

    @Test func droppingLastOwnerWithNativeCallbacksInFlightDoesNotDeadlock() throws {
        let buffer = try makeBuffer(width: 3840, height: 2160)
        for _ in 0..<40 {
            let destroyed = Mutex(false)
            do {
                let encoder = ScreenVideoEncoder()
                let lifetime = EncoderLifetimeProbe { destroyed.withLock { $0 = true } }
                encoder.setCallback { [lifetime] _, _ in withExtendedLifetime(lifetime) { true } }
                #expect(encoder.startEncode(with: settings(width: 3840, height: 2160), numberOfCores: 1) == 0)
                for id in UInt32(1)...4 {
                    #expect(encoder.encode(frame(buffer, id: id), codecSpecificInfo: nil, frameTypes: []) == 0)
                }
            }
            #expect(waitUntil { destroyed.withLock { $0 } })
        }
    }
}

/// Retained only by the callback after the test scope exits. Its destruction
/// follows the encoder's deinit body, unlike a weak reference becoming nil.
private final class EncoderLifetimeProbe: Sendable {
    let didDestroy: @Sendable () -> Void
    init(_ didDestroy: @escaping @Sendable () -> Void) { self.didDestroy = didDestroy }
    deinit { didDestroy() }
}
