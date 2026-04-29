import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import OSLog
package final class VirtualDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    private var handler: (@MainActor () -> Void)?
    nonisolated(unsafe) private var isRunning = false

    @discardableResult
    package func start(handler: @escaping @MainActor () -> Void) -> Bool {
        self.handler = handler
        guard !isRunning else { return true }

        let userInfo = Unmanaged.passRetained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        guard result == .success else {
            Unmanaged<VirtualDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
            return false
        }
        isRunning = true
        return true
    }

    package func stop() {
        guard isRunning else {
            handler = nil
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        isRunning = false
        handler = nil
        Unmanaged<VirtualDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
    }

    deinit {
        assert(!isRunning, "VirtualDisplayReconfigurationMonitor must be stopped before deallocation.")
    }

    private nonisolated static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        displayID,
        flags,
        userInfo in
        guard let userInfo else { return }

        let monitor = Unmanaged<VirtualDisplayReconfigurationMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            AppLog.virtualDisplay.debug(
                "Display reconfiguration callback (displayID: \(displayID, privacy: .public), flags: \(flags.rawValue, privacy: .public))."
            )
            monitor.handler?()
        }
    }
}
