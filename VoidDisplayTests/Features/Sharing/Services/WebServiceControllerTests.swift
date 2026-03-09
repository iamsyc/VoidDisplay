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
        let harness = WebServiceServerHarness()
        let sut = WebServiceController(
            webServiceServerFactory: harness.makeServer
        )
        var states: [WebServiceLifecycleState] = []
        sut.onLifecycleStateChanged = { state in
            states.append(state)
        }

        let port: UInt16 = 18082
        guard let startup = await beginControlledStartup(
            harness: harness,
            sut: sut,
            requestedPort: port,
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in WebRTCSessionHub() }
        ) else {
            return
        }
        startup.server.finishStart(with: .ready(boundPort: port))

        let result = await startup.startTask.value
        guard case .started = result else {
            Issue.record("Expected web service start to succeed for unexpected-stop test.")
            return
        }

        startup.server.emitStop(.listenerFailed)

        let failedObserved = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
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
        let harness = WebServiceServerHarness()
        let sut = WebServiceController(webServiceServerFactory: harness.makeServer)
        var lifecycleStates: [WebServiceLifecycleState] = []
        var runningStates: [Bool] = []
        sut.onLifecycleStateChanged = { lifecycleStates.append($0) }
        sut.onRunningStateChanged = { runningStates.append($0) }

        let requestedPort: UInt16 = 18081
        guard let startup = await beginControlledStartup(
            harness: harness,
            sut: sut,
            requestedPort: requestedPort
        ) else {
            return
        }

        sut.stop()
        startup.server.finishStart(with: .ready(boundPort: requestedPort))

        let result = await startup.startTask.value
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
        #expect(startup.server.stopReasons == [.requested])
    }

    @Test
    func staleCancelledCallbackAfterStopDoesNotChangeStoppedState() async {
        let harness = WebServiceServerHarness()
        let sut = WebServiceController(webServiceServerFactory: harness.makeServer)

        let requestedPort: UInt16 = 18083
        guard let startup = await beginControlledStartup(
            harness: harness,
            sut: sut,
            requestedPort: requestedPort
        ) else {
            return
        }

        sut.stop()
        startup.server.emitStop(.listenerCancelled)
        startup.server.finishStart(with: .failed(error: NSError(domain: "test", code: 1)))

        _ = await startup.startTask.value
        #expect(sut.lifecycleState == .stopped)
    }

    @Test
    func staleStopFromPriorServerDoesNotPolluteReplacementRun() async {
        let harness = WebServiceServerHarness()
        let sut = WebServiceController(webServiceServerFactory: harness.makeServer)

        let firstPort: UInt16 = 18084
        let secondPort: UInt16 = 18085

        guard let firstStartup = await beginControlledStartup(
            harness: harness,
            sut: sut,
            requestedPort: firstPort
        ) else {
            return
        }

        sut.stop()
        firstStartup.server.finishStart(with: .ready(boundPort: firstPort))
        _ = await firstStartup.startTask.value

        guard let secondStartup = await beginControlledStartup(
            harness: harness,
            sut: sut,
            requestedPort: secondPort,
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in WebRTCSessionHub() }
        ) else {
            return
        }

        firstStartup.server.emitStop(.listenerFailed)
        secondStartup.server.finishStart(with: .ready(boundPort: secondPort))

        let result = await secondStartup.startTask.value
        #expect(result == .started(.init(requestedPort: secondPort, boundPort: secondPort)))
        #expect(sut.lifecycleState == .running(.init(requestedPort: secondPort, boundPort: secondPort)))
    }

    private func beginControlledStartup(
        harness: WebServiceServerHarness,
        sut: WebServiceController,
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState = { _ in .unknown },
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub? = { _ in nil }
    ) async -> (startTask: Task<WebServiceStartResult, Never>, server: ControlledWebServiceServer)? {
        let existingServerCount = harness.createdServers.count
        let startTask = Task {
            await sut.start(
                requestedPort: requestedPort,
                targetStateProvider: targetStateProvider,
                sessionHubProvider: sessionHubProvider
            )
        }

        let startInvoked = await waitUntil {
            guard harness.createdServers.count > existingServerCount,
                  let server = harness.createdServers.last else {
                return false
            }
            return server.startCallCount == 1
        }
        #expect(startInvoked)

        guard startInvoked,
              harness.createdServers.count > existingServerCount,
              let server = harness.createdServers.last else {
            Issue.record("Expected controlled web service server to enter startListener().")
            startTask.cancel()
            return nil
        }

        return (startTask, server)
    }

    private func availablePort() throws -> UInt16 {
        let (descriptor, port) = try openBoundSocket()
        close(descriptor)
        return port
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
private final class WebServiceServerHarness {
    private(set) var createdServers: [ControlledWebServiceServer] = []

    func makeServer(
        _ port: NWEndpoint.Port,
        _ targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        _ sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        _ onListenerStopped: (@MainActor @Sendable (WebServiceServerStopReason) -> Void)?
    ) throws -> any WebServiceServerProtocol {
        _ = port
        _ = targetStateProvider
        _ = sessionHubProvider
        let server = ControlledWebServiceServer(onListenerStopped: onListenerStopped)
        createdServers.append(server)
        return server
    }
}

@MainActor
private final class ControlledWebServiceServer: WebServiceServerProtocol {
    private var startContinuation: CheckedContinuation<WebServer.ListenerStartResult, Never>?
    private let onListenerStopped: (@MainActor @Sendable (WebServiceServerStopReason) -> Void)?
    var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var stopReasons: [WebServiceServerStopReason] = []
    private(set) var disconnectCallCount = 0
    var activeStreamClientCount: Int = 0

    init(onListenerStopped: (@MainActor @Sendable (WebServiceServerStopReason) -> Void)?) {
        self.onListenerStopped = onListenerStopped
    }

    deinit {
        let hasPendingStartContinuation = startContinuation != nil
        if hasPendingStartContinuation {
            assertionFailure("ControlledWebServiceServer deinitialized with an unresolved startContinuation. Tests must finish or fail startup explicitly.")
        }
    }

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

    func emitStop(_ reason: WebServiceServerStopReason) {
        onListenerStopped?(reason)
    }

    func stopListener(reason: WebServiceServerStopReason) {
        stopCallCount += 1
        stopReasons.append(reason)
    }

    func disconnectAllStreamClients() {
        disconnectCallCount += 1
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        _ = target
        return 0
    }
}
