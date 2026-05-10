import VoidDisplayVirtualDisplay
import VoidDisplayFoundation
import Foundation

@MainActor
package final class TestVirtualDisplayClock: VirtualDisplayClocking {
    package private(set) var currentTime: TimeInterval

    package init(startTime: TimeInterval = 0) {
        self.currentTime = startTime
    }

    package func now() -> TimeInterval {
        currentTime
    }

    package func sleep(for duration: Duration) async {
        let components = duration.components
        let seconds =
            Double(components.seconds) +
            (Double(components.attoseconds) / 1_000_000_000_000_000_000)
        var remaining = max(seconds, 0)
        if remaining == 0 {
            await Task.yield()
            return
        }
        while remaining > 0 {
            let step = min(0.05, remaining)
            currentTime += step
            remaining -= step
            await Task.yield()
        }
    }
}
