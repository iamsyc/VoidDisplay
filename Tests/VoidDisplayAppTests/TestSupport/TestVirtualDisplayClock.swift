@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
import Foundation

@MainActor
final class TestVirtualDisplayClock: VirtualDisplayClocking {
    private(set) var currentTime: TimeInterval

    init(startTime: TimeInterval = 0) {
        self.currentTime = startTime
    }

    func now() -> TimeInterval {
        currentTime
    }

    func sleep(for duration: Duration) async {
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
