import Foundation

@MainActor
protocol VirtualDisplayClocking: AnyObject {
    func now() -> TimeInterval
    func sleep(for duration: Duration) async
}

@MainActor
final class SystemVirtualDisplayClock: VirtualDisplayClocking {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for duration: Duration) async {
        guard duration > .zero else {
            await Task.yield()
            return
        }
        do {
            try await Task.sleep(for: duration)
        } catch {
            // Ignore cancellation and let callers decide how to proceed.
        }
    }
}
