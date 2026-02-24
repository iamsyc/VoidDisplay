import CoreGraphics
import OSLog

protocol DisplayReconfigurationMonitoring: AnyObject {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

final class VirtualDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    private var handler: (@MainActor () -> Void)?
    nonisolated(unsafe) private var isRunning = false

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
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

    func stop() {
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
