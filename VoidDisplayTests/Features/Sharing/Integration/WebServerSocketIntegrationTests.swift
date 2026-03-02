import Foundation
import Darwin
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
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
        let result = try await Task.detached { try probeOversizedFrameClose(port: portValue) }.value

        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.didClose)
    }

    @Test func clientCloseFrameRemovesActiveClient() async throws {
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

        let result = try await Task.detached { try probeClientCloseFrame(port: portValue) }.value
        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.didClose)

        let deadline = Date().addingTimeInterval(2.0)
        var clientCleared = server.activeStreamClientCount == 0 && sessionHub.activeClientCount == 0
        while !clientCleared, Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
            clientCleared = server.activeStreamClientCount == 0 && sessionHub.activeClientCount == 0
        }

        #expect(clientCleared)
    }

    @Test func binarySignalFrameClosesWithProtocolCodeAndRemovesActiveClient() async throws {
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

        let result = try await Task.detached { try probeBinarySignalFrameClose(port: portValue) }.value
        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.closeObservation.didClose)
        #expect(result.closeObservation.closeCode == 1003)

        let deadline = Date().addingTimeInterval(2.0)
        var clientCleared = server.activeStreamClientCount == 0 && sessionHub.activeClientCount == 0
        while !clientCleared, Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
            clientCleared = server.activeStreamClientCount == 0 && sessionHub.activeClientCount == 0
        }

        #expect(clientCleared)
    }

}

private extension String {
    static func orThrowUTF8(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw SocketIntegrationError.receiveFailed
        }
        return value
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

private func probeOversizedFrameClose(
    port: UInt16,
    maxAttempts: Int = 3
) throws -> (handshakeText: String, didClose: Bool) {
    var lastError: Error = SocketIntegrationError.receiveFailed
    for attempt in 1...maxAttempts {
        do {
            let socketFD = try connectLoopbackSocket(port: port)
            defer { close(socketFD) }

            try sendAll(socketFD, data: websocketUpgradeRequest(path: "/signal", port: port))
            let handshake = try readUntilHeaderTerminator(
                from: socketFD,
                timeoutMilliseconds: 500,
                deadlineSeconds: 8
            )
            let terminator = Data("\r\n\r\n".utf8)
            guard let headerRange = handshake.range(of: terminator) else {
                throw SocketIntegrationError.receiveTimeout
            }
            let handshakeText = try String.orThrowUTF8(Data(handshake[..<headerRange.upperBound]))

            let oversizedChunk = makeIncompleteMaskedFrameChunk(
                announcedPayloadLength: 900_000,
                partialPayloadBytes: 180_000
            )
            try sendAll(socketFD, data: oversizedChunk)
            try sendAll(socketFD, data: oversizedChunk)
            let didClose = try waitForCloseOrEOF(from: socketFD, deadlineSeconds: 15)
            guard didClose else {
                throw SocketIntegrationError.receiveTimeout
            }
            return (handshakeText, true)
        } catch {
            lastError = error
            if attempt < maxAttempts {
                usleep(100_000)
                continue
            }
        }
    }
    throw lastError
}

private func makeMaskedCloseFrame(code: UInt16 = 1000) -> Data {
    var payloadCode = code.bigEndian
    let payload = withUnsafeBytes(of: &payloadCode) { Data($0) }
    let mask: [UInt8] = [0x01, 0x23, 0x45, 0x67]
    var frame = Data([0x88, 0x80 | UInt8(payload.count)])
    frame.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() {
        frame.append(byte ^ mask[index % 4])
    }
    return frame
}

private func probeClientCloseFrame(
    port: UInt16,
    maxAttempts: Int = 3
) throws -> (handshakeText: String, didClose: Bool) {
    var lastError: Error = SocketIntegrationError.receiveFailed
    for attempt in 1...maxAttempts {
        do {
            let socketFD = try connectLoopbackSocket(port: port)
            defer { close(socketFD) }

            try sendAll(socketFD, data: websocketUpgradeRequest(path: "/signal", port: port))
            let handshake = try readUntilHeaderTerminator(
                from: socketFD,
                timeoutMilliseconds: 500,
                deadlineSeconds: 8
            )
            let terminator = Data("\r\n\r\n".utf8)
            guard let headerRange = handshake.range(of: terminator) else {
                throw SocketIntegrationError.receiveTimeout
            }
            let handshakeText = try String.orThrowUTF8(Data(handshake[..<headerRange.upperBound]))

            try sendAll(socketFD, data: makeMaskedCloseFrame())
            let didClose = try waitForCloseOrEOF(from: socketFD, deadlineSeconds: 10)
            guard didClose else {
                throw SocketIntegrationError.receiveTimeout
            }
            return (handshakeText, didClose)
        } catch {
            lastError = error
            if attempt < maxAttempts {
                usleep(100_000)
                continue
            }
        }
    }
    throw lastError
}

private func probeBinarySignalFrameClose(
    port: UInt16,
    maxAttempts: Int = 3
) throws -> (handshakeText: String, closeObservation: WebSocketCloseObservation) {
    var lastError: Error = SocketIntegrationError.receiveFailed
    for attempt in 1...maxAttempts {
        do {
            let socketFD = try connectLoopbackSocket(port: port)
            defer { close(socketFD) }

            try sendAll(socketFD, data: websocketUpgradeRequest(path: "/signal", port: port))
            let handshake = try readUntilHeaderTerminator(
                from: socketFD,
                timeoutMilliseconds: 500,
                deadlineSeconds: 8
            )
            let terminator = Data("\r\n\r\n".utf8)
            guard let headerRange = handshake.range(of: terminator) else {
                throw SocketIntegrationError.receiveTimeout
            }
            let handshakeText = try String.orThrowUTF8(Data(handshake[..<headerRange.upperBound]))

            try sendAll(socketFD, data: makeMaskedBinaryFrame(payload: Data([0x01, 0x02, 0x03])))
            let closeObservation = try waitForCloseObservation(from: socketFD, deadlineSeconds: 10)
            guard closeObservation.didClose else {
                throw SocketIntegrationError.receiveTimeout
            }
            return (handshakeText, closeObservation)
        } catch {
            lastError = error
            if attempt < maxAttempts {
                usleep(100_000)
                continue
            }
        }
    }
    throw lastError
}
