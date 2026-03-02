import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class EndToEndFakeCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func stop() async {}
}

private final class EndToEndMockSCDisplayBox: NSObject {
    @objc let displayID: CGDirectDisplayID
    @objc let width: Int
    @objc let height: Int
    @objc let frame: CGRect

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = CGRect(x: 0, y: 0, width: width, height: height)
        super.init()
    }
}

private enum EndToEndMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = EndToEndMockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

@Suite(.serialized)
struct SharingEndToEndIntegrationTests {
    @MainActor
    @Test
    func sharingLifecycleRoutesRemainConsistent() async throws {
        let storeURL = temporaryStoreURL()
        let registry = DisplayCaptureRegistry(captureSessionFactory: { _ in
            EndToEndFakeCaptureSession()
        })
        let coordinator = DisplaySharingCoordinator(
            idStore: DisplayShareIDStore(storeURL: storeURL),
            captureRegistry: registry
        )
        let webServiceController = WebServiceController()
        let service = SharingService(
            webServiceController: webServiceController,
            sharingCoordinator: coordinator
        )

        let displayID = CGDirectDisplayID(9101)
        let display = EndToEndMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        service.registerShareableDisplays([display], virtualSerialResolver: { _ in nil })

        let requestedPort = try availablePort()
        let startResult = await service.startWebService(requestedPort: requestedPort)
        let binding: WebServiceBinding
        switch startResult {
        case .started(let value), .alreadyRunning(let value):
            binding = value
        case .failed(let failure):
            Issue.record("Expected web service start success but got failure: \(String(describing: failure))")
            return
        }
        defer {
            service.stopWebService()
        }
        let boundPort = binding.boundPort

        try await service.startSharing(display: display)
        let shareID = try #require(service.shareID(for: displayID))

        let displayPath = "/display/\(shareID)"
        let displayRequest = Data("GET \(displayPath) HTTP/1.1\r\nHost: 127.0.0.1:\(boundPort)\r\n\r\n".utf8)
        let displayResponse = try await Task.detached {
            try sendRequestAndReadUntilClose(port: boundPort, request: displayRequest)
        }.value
        let displayText = try #require(String(data: displayResponse, encoding: .utf8))
        #expect(displayText.contains("HTTP/1.1 200 OK"))

        let signalPath = "/signal/\(shareID)"
        let signalUpgradeResponse = try await Task.detached {
            try sendRequestAndReadPartialResponse(
                port: boundPort,
                request: websocketUpgradeRequest(path: signalPath, port: boundPort)
            )
        }.value
        let signalUpgradeText = try #require(String(data: signalUpgradeResponse, encoding: .utf8))
        #expect(signalUpgradeText.contains("101 Switching Protocols"))

        service.stopSharing(displayID: displayID)
        let stoppedSignalRequest = Data("GET \(signalPath) HTTP/1.1\r\nHost: 127.0.0.1:\(boundPort)\r\n\r\n".utf8)
        let stoppedSignalResponse = try await Task.detached {
            try sendRequestAndReadUntilClose(port: boundPort, request: stoppedSignalRequest)
        }.value
        let stoppedSignalText = try #require(String(data: stoppedSignalResponse, encoding: .utf8))
        #expect(stoppedSignalText.contains("503 Service Unavailable"))

        service.stopWebService()
        let unreachableAfterStop = await waitForConnectionFailure(
            port: boundPort,
            path: displayPath,
            timeout: .seconds(3)
        )
        #expect(unreachableAfterStop)
    }

    private func waitForConnectionFailure(
        port: UInt16,
        path: String,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            do {
                let request = Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
                _ = try sendRequestAndReadUntilClose(port: port, request: request)
                try? await Task.sleep(for: .milliseconds(50))
            } catch {
                return true
            }
        }
        do {
            let request = Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
            _ = try sendRequestAndReadUntilClose(port: port, request: request)
            return false
        } catch {
            return true
        }
    }

    private func temporaryStoreURL() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharing-e2e-\(UUID().uuidString)", isDirectory: true)
        return base.appendingPathComponent("shared-display-ids.json", isDirectory: false)
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }
        defer { close(descriptor) }

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
            throw POSIXError(errnoValue)
        }

        return UInt16(bigEndian: boundAddress.sin_port)
    }
}
