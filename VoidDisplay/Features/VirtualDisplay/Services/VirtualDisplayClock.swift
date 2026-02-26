import Foundation

@MainActor
protocol VirtualDisplayClocking: AnyObject {
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async
}

@MainActor
final class SystemVirtualDisplayClock: VirtualDisplayClocking {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // Ignore cancellation and let callers decide how to proceed.
        }
    }
}
