import Foundation
import Network
import Darwin
import Testing
@testable import VoidDisplay

@MainActor
struct WebServiceControllerTests {
    @Test
    func classifyStartFailureMapsAddressInUseToPortInUse() {
        let failure = WebServiceController.classifyStartFailure(
            error: NWError.posix(.EADDRINUSE),
            requestedPort: 8081
        )

        #expect(failure == .portInUse(port: 8081))
    }

    @Test
    func classifyStartFailureMapsPermissionDenied() {
        let failure = WebServiceController.classifyStartFailure(
            error: NWError.posix(.EACCES),
            requestedPort: 8443
        )

        #expect(failure == .permissionDenied(port: 8443))
    }

    @Test
    func startRejectsOutOfRangePortBeforeListenerStart() async {
        let sut = WebServiceController()

        let result = await sut.start(
            requestedPort: 1000,
            targetStateProvider: { _ in .unknown },
            sessionHubProvider: { _ in nil }
        )

        #expect(result == .failed(.invalidPort(.outOfRange)))
        #expect(sut.lifecycleState == .failed(.invalidPort(.outOfRange)))
    }

    @Test
    func lifecycleStateEmitsStartingThenFailedForInvalidPort() async {
        let sut = WebServiceController()
        var states: [WebServiceLifecycleState] = []
        sut.onLifecycleStateChanged = { state in
            states.append(state)
        }

        _ = await sut.start(
            requestedPort: 999,
            targetStateProvider: { _ in .unknown },
            sessionHubProvider: { _ in nil }
        )

        #expect(states == [
            .starting(requestedPort: 999),
            .failed(.invalidPort(.outOfRange))
        ])
    }

    @Test
    func stopTransitionsToStoppedFromFailureState() async {
        let sut = WebServiceController()
        var states: [WebServiceLifecycleState] = []
        sut.onLifecycleStateChanged = { state in
            states.append(state)
        }

        _ = await sut.start(
            requestedPort: 999,
            targetStateProvider: { _ in .unknown },
            sessionHubProvider: { _ in nil }
        )
        sut.stop()

        #expect(states == [
            .starting(requestedPort: 999),
            .failed(.invalidPort(.outOfRange)),
            .stopping,
            .stopped
        ])
    }

    @Test
    func runningStateCallbackRemainsSilentWhenRunningFlagDoesNotChange() async {
        let sut = WebServiceController()
        var runningStates: [Bool] = []
        sut.onRunningStateChanged = { isRunning in
            runningStates.append(isRunning)
        }

        _ = await sut.start(
            requestedPort: 999,
            targetStateProvider: { _ in .unknown },
            sessionHubProvider: { _ in nil }
        )
        sut.stop()

        #expect(runningStates.isEmpty)
    }

    @Test
    func timedOutFailureCarriesRequestedPort() {
        let failure = WebServiceStartFailure.timedOut(port: 8081)

        #expect(failure == .timedOut(port: 8081))
    }

    @Test
    func preflightBindingFailureReturnsPortInUseWhenSocketAlreadyBound() throws {
        let (socketDescriptor, port) = try openBoundSocket()
        defer { close(socketDescriptor) }

        let failure = WebServiceController.preflightBindingFailure(for: port)

        #expect(failure == .portInUse(port: port))
    }

    @Test
    func unexpectedListenerStopTransitionsLifecycleToFailed() async throws {
        let sut = WebServiceController()
        var states: [WebServiceLifecycleState] = []
        sut.onLifecycleStateChanged = { state in
            states.append(state)
        }

        let port = try availablePort()
        let result = await sut.start(
            requestedPort: port,
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in WebRTCSessionHub() }
        )
        guard case .started = result else {
            Issue.record("Expected web service start to succeed for unexpected-stop test.")
            return
        }

        sut.currentServer?.stopListener()

        let failedObserved = await waitUntil(timeout: .seconds(2)) {
            if case .failed = sut.lifecycleState {
                return true
            }
            return false
        }
        #expect(failedObserved)
        #expect(
            states.contains(where: { state in
                if case .failed(.listenerFailed(let failedPort, let message)) = state {
                    return failedPort == port && message.contains("unexpectedly")
                }
                return false
            })
        )
    }

    @Test
    func startupSupersededByStopReturnsSupersededFailureWithoutRunningTransition() async {
        let fakeServer = ControlledWebServiceServer()
        let sut = WebServiceController(
            webServiceServerFactory: { _, _, _, _ in
                fakeServer
            }
        )
        var lifecycleStates: [WebServiceLifecycleState] = []
        var runningStates: [Bool] = []
        sut.onLifecycleStateChanged = { lifecycleStates.append($0) }
        sut.onRunningStateChanged = { runningStates.append($0) }

        let requestedPort: UInt16 = 18081
        let startTask = Task {
            await sut.start(
                requestedPort: requestedPort,
                targetStateProvider: { _ in .unknown },
                sessionHubProvider: { _ in nil }
            )
        }

        let startInvoked = await waitUntil {
            fakeServer.startCallCount == 1
        }
        #expect(startInvoked)

        sut.stop()
        fakeServer.finishStart(with: .ready(boundPort: requestedPort))

        let result = await startTask.value
        guard case .failed(.listenerFailed(let failedPort, let message)) = result else {
            Issue.record("Expected superseded startup failure.")
            return
        }
        #expect(failedPort == requestedPort)
        #expect(!message.isEmpty)
        #expect(lifecycleStates == [
            .starting(requestedPort: requestedPort),
            .stopping,
            .stopped
        ])
        #expect(runningStates.isEmpty)
    }

    private func availablePort() throws -> UInt16 {
        let (descriptor, port) = try openBoundSocket()
        close(descriptor)
        return port
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func openBoundSocket() throws -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let errnoValue = POSIXErrorCode(rawValue: errno) ?? .EFAULT
            close(descriptor)
            throw POSIXError(errnoValue)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var boundAddress = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            let errnoValue = POSIXErrorCode(rawValue: errno) ?? .EFAULT
            close(descriptor)
            throw POSIXError(errnoValue)
        }

        return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    }
}

@MainActor
private final class ControlledWebServiceServer: WebServiceServerProtocol {
    private var startContinuation: CheckedContinuation<WebServer.ListenerStartResult, Never>?
    var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var disconnectCallCount = 0
    var activeStreamClientCount: Int = 0

    func startListener() async -> WebServer.ListenerStartResult {
        startCallCount += 1
        return await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finishStart(with result: WebServer.ListenerStartResult) {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: result)
    }

    func stopListener() {
        stopCallCount += 1
    }

    func disconnectAllStreamClients() {
        disconnectCallCount += 1
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        _ = target
        return 0
    }
}
