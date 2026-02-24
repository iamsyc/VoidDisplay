import CoreGraphics
import Foundation

@MainActor
final class DebouncingDisplayReconfigurationMonitor {
    private var handler: (@MainActor () -> Void)?
    private var debounceTask: Task<Void, Never>?
    private let debounceNanoseconds: UInt64
    nonisolated(unsafe) private var isRunning = false

    init(debounceNanoseconds: UInt64 = 300_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

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
            Unmanaged<DebouncingDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else {
            handler = nil
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            userInfo
        )
        isRunning = false
        handler = nil
        debounceTask?.cancel()
        debounceTask = nil
        Unmanaged<DebouncingDisplayReconfigurationMonitor>.fromOpaque(userInfo).release()
    }

    deinit {
        assert(!isRunning, "DebouncingDisplayReconfigurationMonitor must be stopped before deallocation.")
    }

    private func handleDisplayChange() {
        debounceTask?.cancel()
        let ns = debounceNanoseconds
        if ns == 0 {
            handler?()
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            self.handler?()
        }
    }

    private nonisolated static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _,
        _,
        userInfo in
        guard let userInfo else { return }

        let monitor = Unmanaged<DebouncingDisplayReconfigurationMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            monitor.handleDisplayChange()
        }
    }
}

extension DebouncingDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {}
