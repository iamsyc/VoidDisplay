import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation

@MainActor
package protocol VirtualDisplayClocking: AnyObject {
    func now() -> TimeInterval
    func sleep(for duration: Duration) async
}

@MainActor
package final class SystemVirtualDisplayClock: VirtualDisplayClocking {
    package func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    package func sleep(for duration: Duration) async {
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
