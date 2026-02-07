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

struct WebServerSocketIntegrationTests {

    @Test func rootRouteSupportsFragmentedSocketRequest() async throws {
        let setup = try await MainActor.run {
            try startServerOnRandomPort(
                isSharingProvider: { false },
                frameProvider: { nil }
            )
        }
        let server = setup.server
        let portValue = setup.port
        defer {
            Task { @MainActor in
                server.stopListener()
            }
        }

        let responseData = try await Task.detached {
            try sendFragmentedRootRequestAndReadResponse(port: portValue)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("Content-Type: text/html; charset=utf-8"))
    }

    @Test func streamRouteSendsMultipleFramesToSocketClient() async throws {
        let setup = try await MainActor.run {
            try startServerOnRandomPort(
                isSharingProvider: { true },
                frameProvider: { Data("frame-data".utf8) }
            )
        }
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = await MainActor.run { WebRequestHandler.streamBoundary }
        defer {
            Task { @MainActor in
                server.stopListener()
            }
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

    @Test func streamRouteSupportsFragmentedSocketRequestHeader() async throws {
        let setup = try await MainActor.run {
            try startServerOnRandomPort(
                isSharingProvider: { true },
                frameProvider: { Data("frame-data".utf8) }
            )
        }
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = await MainActor.run { WebRequestHandler.streamBoundary }
        defer {
            Task { @MainActor in
                server.stopListener()
            }
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
        let setup = try await MainActor.run {
            try startServerOnRandomPort(
                isSharingProvider: { true },
                frameProvider: { Data("frame-data".utf8) }
            )
        }
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = await MainActor.run { WebRequestHandler.streamBoundary }
        defer {
            Task { @MainActor in
                server.stopListener()
            }
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
        let setup = try await MainActor.run {
            try startServerOnRandomPort(
                isSharingProvider: { true },
                frameProvider: { largeFrame }
            )
        }
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = await MainActor.run { WebRequestHandler.streamBoundary }
        defer {
            Task { @MainActor in
                server.stopListener()
            }
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
        let sharingState = await MainActor.run {
            SharingState(isSharing: true)
        }
        let setup = try await MainActor.run {
            try startServerOnRandomPort(
                isSharingProvider: { sharingState.isSharing },
                frameProvider: { Data("frame-data".utf8) }
            )
        }
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = await MainActor.run { WebRequestHandler.streamBoundary }
        defer {
            Task { @MainActor in
                server.stopListener()
            }
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

        await MainActor.run {
            sharingState.isSharing = false
        }

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
}
