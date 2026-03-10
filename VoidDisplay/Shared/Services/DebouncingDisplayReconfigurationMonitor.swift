import CoreGraphics
import Foundation

@MainActor
final class DebouncingDisplayReconfigurationMonitor {
    typealias RegisterCallback = @Sendable (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError
    typealias RemoveCallback = @Sendable (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> Void
    typealias SleepOperation = @Sendable (Duration) async -> Void

    private var handler: (@MainActor () -> Void)?
    private var debounceTask: Task<Void, Never>?
    private let debounceDuration: Duration
    private let registerCallback: RegisterCallback
    private let removeCallback: RemoveCallback
    private let sleep: SleepOperation
    nonisolated(unsafe) private var isRunning = false

    init(
        debounceDuration: Duration = .milliseconds(300),
        registerCallback: @escaping RegisterCallback = { callback, userInfo in
            CGDisplayRegisterReconfigurationCallback(callback, userInfo)
        },
        removeCallback: @escaping RemoveCallback = { callback, userInfo in
            CGDisplayRemoveReconfigurationCallback(callback, userInfo)
        },
        sleep: @escaping SleepOperation = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.debounceDuration = debounceDuration
        self.registerCallback = registerCallback
        self.removeCallback = removeCallback
        self.sleep = sleep
    }

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        self.handler = handler
        guard !isRunning else { return true }

        let userInfo = Unmanaged.passRetained(self).toOpaque()
        let result = registerCallback(
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
        removeCallback(
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
        if debounceDuration <= .zero {
            handler?()
            return
        }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(self.debounceDuration)
            guard !Task.isCancelled else { return }
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
