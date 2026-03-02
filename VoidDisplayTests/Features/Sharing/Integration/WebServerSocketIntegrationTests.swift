import Foundation
import Darwin
import Testing
@testable import VoidDisplay

@MainActor
struct WebServerSocketIntegrationTests {

    @Test func rootRouteSupportsFragmentedSocketRequest() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .unknown },
            sessionHubProvider: { _ in nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("VoidDisplay Share"))
    }

    @Test func liveRouteUpgradesToWebSocketWhenTargetActive() async throws {
        let sessionHub = WebRTCSessionHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            sessionHubProvider: { target in
                target == .main ? sessionHub : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = websocketUpgradeRequest(path: "/signal", port: portValue)
        let responseData = try await Task.detached {
            try sendRequestAndReadPartialResponse(port: portValue, request: request)
        }.value
        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("101 Switching Protocols"))
        #expect(responseText.contains("Sec-WebSocket-Accept"))
    }

    @Test func streamRouteReturnsNotFound() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in WebRTCSessionHub() }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value
        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("404 Not Found"))
    }

    @Test func oversizedIncompleteSignalFrameClosesConnection() async throws {
        let sessionHub = WebRTCSessionHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            sessionHubProvider: { target in
                target == .main ? sessionHub : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let socketFD = try connectLoopbackSocket(port: portValue)
        defer { close(socketFD) }

        try sendAll(socketFD, data: websocketUpgradeRequest(path: "/signal", port: portValue))
        let handshake = try readUntilHeaderTerminator(from: socketFD)
        let handshakeText = try #require(String(data: handshake, encoding: .utf8))
        #expect(handshakeText.contains("101 Switching Protocols"))

        let oversizedChunk = makeIncompleteMaskedFrameChunk(
            announcedPayloadLength: 900_000,
            partialPayloadBytes: 180_000
        )
        try sendAll(socketFD, data: oversizedChunk)
        try sendAll(socketFD, data: oversizedChunk)

        #expect(try waitForCloseOrEOF(from: socketFD))
    }

    private func readUntilHeaderTerminator(from fd: Int32) throws -> Data {
        configureReceiveTimeout(fd: fd, milliseconds: 2_000)
        let terminator = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var collected = Data()
        while true {
            let bytes = recv(fd, &buffer, buffer.count, 0)
            if bytes > 0 {
                collected.append(buffer, count: bytes)
                if collected.range(of: terminator) != nil {
                    return collected
                }
                continue
            }
            if bytes == 0 {
                return collected
            }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw SocketIntegrationError.receiveTimeout
            }
            throw SocketIntegrationError.receiveFailed
        }
    }

    private func waitForCloseOrEOF(from fd: Int32) throws -> Bool {
        configureReceiveTimeout(fd: fd, milliseconds: 2_000)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()
        while true {
            let bytes = recv(fd, &buffer, buffer.count, 0)
            if bytes > 0 {
                accumulated.append(buffer, count: bytes)
                let decoded = decodeWebSocketFrames(from: accumulated)
                accumulated = decoded.remainder
                if decoded.frames.contains(where: { frame in
                    if case .close = frame { return true }
                    return false
                }) {
                    return true
                }
                continue
            }
            if bytes == 0 {
                return true
            }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                return false
            }
            throw SocketIntegrationError.receiveFailed
        }
    }

    private func makeIncompleteMaskedFrameChunk(
        announcedPayloadLength: UInt64,
        partialPayloadBytes: Int
    ) -> Data {
        var data = Data()
        data.append(0x81)
        data.append(0xFF)
        var payloadLength = announcedPayloadLength.bigEndian
        withUnsafeBytes(of: &payloadLength) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x11, 0x22, 0x33, 0x44])
        data.append(Data(repeating: 0x00, count: max(0, partialPayloadBytes)))
        return data
    }
}
