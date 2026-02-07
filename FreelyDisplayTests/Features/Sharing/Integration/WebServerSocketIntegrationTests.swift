import Foundation
import Testing
@testable import FreelyDisplay

@MainActor
private final class SharingState {
    var isSharing: Bool

    init(isSharing: Bool) {
        self.isSharing = isSharing
    }
}

@MainActor
struct WebServerSocketIntegrationTests {

    @Test func rootRouteSupportsFragmentedSocketRequest() async throws {
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { false },
            frameProvider: { nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let responseData = try await Task.detached {
            try sendFragmentedRootRequestAndReadResponse(port: portValue)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("Content-Type: text/html; charset=utf-8"))
    }

    @Test func streamRouteSendsMultipleFramesToSocketClient() async throws {
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { true },
            frameProvider: { Data("frame-data".utf8) }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let responseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                boundary: streamBoundary,
                minimumFrameCount: 2
            )
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("multipart/x-mixed-replace"))
        #expect(responseText.contains("boundary=\(streamBoundary)"))
        let boundary = Data("--\(streamBoundary)\r\n".utf8)
        #expect(countOccurrences(of: boundary, in: responseData) >= 2)
    }

    @Test func streamRouteRejectsNonGETMethodWith405() async throws {
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { true },
            frameProvider: { Data("frame-data".utf8) }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let request = Data("POST /stream HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\nContent-Length: 0\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(
                port: portValue,
                request: request
            )
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("405 Method Not Allowed"))
        #expect(responseText.contains("Allow: GET"))
    }

    @Test func streamRouteSupportsFragmentedSocketRequestHeader() async throws {
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { true },
            frameProvider: { Data("frame-data".utf8) }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let responseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                boundary: streamBoundary,
                minimumFrameCount: 1,
                fragmentedHeader: true
            )
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("multipart/x-mixed-replace"))
        let boundary = Data("--\(streamBoundary)\r\n".utf8)
        #expect(countOccurrences(of: boundary, in: responseData) >= 1)
    }

    @Test func streamRouteBroadcastsFramesToAllConnectedClients() async throws {
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { true },
            frameProvider: { Data("frame-data".utf8) }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let firstTask = Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                boundary: streamBoundary,
                minimumFrameCount: 2
            )
        }
        let secondTask = Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                boundary: streamBoundary,
                minimumFrameCount: 2
            )
        }

        let firstResponseData = try await firstTask.value
        let secondResponseData = try await secondTask.value

        let firstText = try #require(String(data: firstResponseData, encoding: .utf8))
        #expect(firstText.contains("HTTP/1.1 200 OK"))
        #expect(firstText.contains("multipart/x-mixed-replace"))
        let secondText = try #require(String(data: secondResponseData, encoding: .utf8))
        #expect(secondText.contains("HTTP/1.1 200 OK"))
        #expect(secondText.contains("multipart/x-mixed-replace"))

        let boundary = Data("--\(streamBoundary)\r\n".utf8)
        #expect(countOccurrences(of: boundary, in: firstResponseData) >= 2)
        #expect(countOccurrences(of: boundary, in: secondResponseData) >= 2)
    }

    @Test func slowClientBackpressureDoesNotBlockFastClient() async throws {
        let largeFrame = Data(repeating: 0xAB, count: 512 * 1024)
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { true },
            frameProvider: { largeFrame }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let slowClientFD = try openStreamSocket(port: portValue)
        defer { close(slowClientFD) }

        // Let server try pushing large frames while slow client is not reading.
        usleep(600_000)

        let fastResponseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                boundary: streamBoundary,
                minimumFrameCount: 3
            )
        }.value

        let slowResponseData = try await Task.detached {
            try readUntilFrameBoundaries(
                from: slowClientFD,
                boundary: streamBoundary,
                minimumCount: 1,
                timeoutMilliseconds: 4000
            )
        }.value

        let boundary = Data("--\(streamBoundary)\r\n".utf8)
        #expect(countOccurrences(of: boundary, in: fastResponseData) >= 3)
        #expect(countOccurrences(of: boundary, in: slowResponseData) >= 1)
    }

    @Test func streamClientDisconnectsWhenSharingStopsAndNewStreamReturns503() async throws {
        let sharingState = SharingState(isSharing: true)
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { sharingState.isSharing },
            frameProvider: { Data("frame-data".utf8) }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let activeClientFD = try openStreamSocket(port: portValue)
        defer { close(activeClientFD) }

        _ = try await Task.detached {
            try readUntilFrameBoundaries(
                from: activeClientFD,
                boundary: streamBoundary,
                minimumCount: 1,
                timeoutMilliseconds: 3000
            )
        }.value

        sharingState.isSharing = false

        _ = try await Task.detached {
            try readUntilSocketClosed(from: activeClientFD, timeoutMilliseconds: 4000)
        }.value

        let unavailableResponse = try await Task.detached {
            let fd = try connectLoopbackSocket(port: portValue)
            defer { close(fd) }
            let request = Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
            try sendAll(fd, data: request)
            _ = shutdown(fd, SHUT_WR)
            return try readAll(from: fd)
        }.value

        let responseText = try #require(String(data: unavailableResponse, encoding: .utf8))
        #expect(responseText.contains("503 Service Unavailable"))
    }

    @Test func oversizedRequestHeaderIsRejected() async throws {
        let setup = try await startServerOnRandomPort(
            isSharingProvider: { false },
            frameProvider: { nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let largeHeaderValue = String(repeating: "a", count: 40_000)
        let requestText = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\nX-Large: \(largeHeaderValue)\r\n\r\n"
        let request = Data(requestText.utf8)

        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(
                port: portValue,
                request: request,
                timeoutMilliseconds: 5000,
                ignoreSendFailure: true
            )
        }.value

        let responseText = String(data: responseData, encoding: .utf8)
        #expect(responseText?.contains("200 OK") != true)
        #expect(responseData.isEmpty || responseText?.contains("400 Bad Request") == true)
    }
}
