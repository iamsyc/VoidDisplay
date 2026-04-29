@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import CoreGraphics
import Testing

private final class DebounceRegistrationHarness: @unchecked Sendable {
    nonisolated(unsafe) private var nextResult: CGError = .success
    nonisolated(unsafe) private var registerCallCountValue = 0
    nonisolated(unsafe) private var removeCallCountValue = 0
    nonisolated(unsafe) private var callback: CGDisplayReconfigurationCallBack?
    nonisolated(unsafe) private var userInfo: UnsafeMutableRawPointer?

    func register(
        callback: @escaping CGDisplayReconfigurationCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> CGError {
        registerCallCountValue += 1
        self.callback = callback
        self.userInfo = userInfo
        return nextResult
    }

    func remove(
        callback _: CGDisplayReconfigurationCallBack,
        userInfo: UnsafeMutableRawPointer
    ) {
        if self.userInfo == userInfo {
            removeCallCountValue += 1
        }
    }

    func setNextResult(_ result: CGError) {
        nextResult = result
    }

    func trigger() {
        guard let callback, let userInfo else { return }
        callback(CGMainDisplayID(), [], userInfo)
    }

    func registerCallCount() -> Int {
        registerCallCountValue
    }

    func removeCallCount() -> Int {
        removeCallCountValue
    }
}

@Suite(.serialized)
@MainActor
struct DebouncingDisplayReconfigurationMonitorTests {
    @Test func startReturnsFalseWhenRegistrationFails() {
        let harness = DebounceRegistrationHarness()
        harness.setNextResult(.failure)
        let monitor = DebouncingDisplayReconfigurationMonitor(
            registerCallback: { callback, userInfo in
                harness.register(callback: callback, userInfo: userInfo)
            },
            removeCallback: { callback, userInfo in
                harness.remove(callback: callback, userInfo: userInfo)
            }
        )

        let started = monitor.start {}

        #expect(started == false)
        #expect(harness.registerCallCount() == 1)
        #expect(harness.removeCallCount() == 0)
    }

    @Test func zeroDebounceInvokesHandlerImmediately() async {
        let harness = DebounceRegistrationHarness()
        let monitor = DebouncingDisplayReconfigurationMonitor(
            debounceDuration: .zero,
            registerCallback: { callback, userInfo in
                harness.register(callback: callback, userInfo: userInfo)
            },
            removeCallback: { callback, userInfo in
                harness.remove(callback: callback, userInfo: userInfo)
            }
        )
        var fireCount = 0

        #expect(monitor.start { fireCount += 1 })
        harness.trigger()

        #expect(await waitUntil { fireCount == 1 })
        monitor.stop()
        #expect(harness.removeCallCount() == 1)
    }

    @Test func repeatedCallbacksCollapseIntoSingleDelivery() async {
        let harness = DebounceRegistrationHarness()
        let monitor = DebouncingDisplayReconfigurationMonitor(
            debounceDuration: .milliseconds(20),
            registerCallback: { callback, userInfo in
                harness.register(callback: callback, userInfo: userInfo)
            },
            removeCallback: { callback, userInfo in
                harness.remove(callback: callback, userInfo: userInfo)
            }
        )
        var fireCount = 0

        #expect(monitor.start { fireCount += 1 })
        harness.trigger()
        harness.trigger()

        #expect(await waitUntil { fireCount == 1 })
        #expect(await staysTrue(timeoutNanoseconds: 80_000_000) { fireCount == 1 })
        monitor.stop()
    }

    @Test func stopCancelsPendingDelivery() async {
        let harness = DebounceRegistrationHarness()
        let monitor = DebouncingDisplayReconfigurationMonitor(
            debounceDuration: .milliseconds(80),
            registerCallback: { callback, userInfo in
                harness.register(callback: callback, userInfo: userInfo)
            },
            removeCallback: { callback, userInfo in
                harness.remove(callback: callback, userInfo: userInfo)
            }
        )
        var fireCount = 0

        #expect(monitor.start { fireCount += 1 })
        harness.trigger()
        monitor.stop()

        #expect(await waitUntil { harness.removeCallCount() == 1 })
        #expect(await staysTrue(timeoutNanoseconds: 140_000_000) { fireCount == 0 })
    }
}
