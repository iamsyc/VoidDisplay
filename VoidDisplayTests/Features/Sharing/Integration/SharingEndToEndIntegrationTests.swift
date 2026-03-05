import CoreGraphics
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
    private let maxStartPortAttempts = 8
    private enum DynamicStartError: Error {
        case message(String)
    }

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

        let startOutcome = await startWebServiceWithDynamicPorts(service: service)
        let binding: WebServiceBinding
        switch startOutcome {
        case .success(let value):
            binding = value
        case .failure(let error):
            Issue.record("Web service start failed: \(String(describing: error))")
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
        return base.appendingPathComponent("display-share-id-mappings.json", isDirectory: false)
    }

    @MainActor
    private func startWebServiceWithDynamicPorts(
        service: SharingService
    ) async -> Result<WebServiceBinding, DynamicStartError> {
        let candidatePorts = TestPortAllocator.randomPortCandidates(count: maxStartPortAttempts)
        var attemptedPorts: [UInt16] = []

        for requestedPort in candidatePorts {
            attemptedPorts.append(requestedPort)
            let startResult = await service.startWebService(requestedPort: requestedPort)
            switch startResult {
            case .started(let binding), .alreadyRunning(let binding):
                print(
                    "[SharingEndToEndIntegrationTests] start success requested=\(requestedPort) bound=\(binding.boundPort) attempted=\(attemptedPorts)"
                )
                return .success(binding)
            case .failed(.portInUse):
                print(
                    "[SharingEndToEndIntegrationTests] start portInUse requested=\(requestedPort) attempted=\(attemptedPorts)"
                )
                continue
            case .failed(let failure):
                let message =
                    "Web service start failed with non-retryable failure \(String(describing: failure)). attemptedPorts=\(attemptedPorts)"
                print("[SharingEndToEndIntegrationTests] \(message)")
                return .failure(.message(message))
            }
        }

        let message = "Web service start exhausted retry budget. attemptedPorts=\(attemptedPorts)"
        print("[SharingEndToEndIntegrationTests] \(message)")
        return .failure(.message(message))
    }
}
