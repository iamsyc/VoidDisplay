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
