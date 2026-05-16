@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharingTestingSupport
import Foundation
import Darwin
import Network
import Testing

@MainActor
@Suite(.serialized)
struct WebServerSocketIntegrationTests {
    private static let mainAliasShareID: UInt32 = 5
    private static let replacementMainAliasShareID: UInt32 = 6

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
            try await sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("VoidDisplay Share"))
    }

    @Test func stoppedListenerAllowsImmediateSamePortRestartAfterActiveWebSocketTraffic() async throws {
        let sessionHub = TestSignalSessionHub()
        let setup = try await startMainSignalServer(sessionHub: sessionHub)
        let firstServer = setup.server
        let portValue = setup.port

        let socket = try await openWebSocket(path: "/signal", port: portValue)
        defer { close(socket) }
        let connected = await waitUntilAsync(timeout: .seconds(2)) {
            firstServer.activeStreamClientCount == 1 && sessionHub.activeClientCount == 1
        }
        #expect(connected)

        firstServer.stopListener()
        #expect(try await waitForSocketClose(socket))

        let rebound = try await startReboundServer(on: portValue)
        let reboundServer = rebound.server
        defer { reboundServer.stopListener() }
        #expect(rebound.boundPort == portValue)
    }

    @Test func liveRouteUpgradesToWebSocketWhenTargetActive() async throws {
        let sessionHub = TestSignalSessionHub()
        let setup = try await startMainSignalServer(sessionHub: sessionHub)
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = websocketUpgradeRequest(path: "/signal", port: portValue)
        let responseData = try await Task.detached {
            try await sendRequestAndReadPartialResponse(port: portValue, request: request)
        }.value
        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("101 Switching Protocols"))
        #expect(responseText.contains("Sec-WebSocket-Accept"))
    }

    @Test func streamRouteReturnsNotFound() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in TestSignalSessionHub() }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try await sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value
        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("404 Not Found"))
    }

    @Test func displayRouteEmbedsBootstrapJSON() async throws {
        setenv("VOIDDISPLAY_WEBRTC_ICE_SERVERS", "stun:127.0.0.1:3478,turn:127.0.0.1:3479", 1)
        defer { unsetenv("VOIDDISPLAY_WEBRTC_ICE_SERVERS") }

        let setup = try await startMainSignalServer(sessionHub: TestSignalSessionHub())
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /display HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try await sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        for snippet in displayPageRequiredSnippets(signalID: Self.mainAliasShareID) {
            #expect(responseText.contains(snippet))
        }
        for snippet in displayPageForbiddenSnippets {
            #expect(!responseText.contains(snippet))
        }
    }

    @Test func secondaryDisplayRouteAlsoUsesGenericPageTitle() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in TestSignalSessionHub() }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /display/7 HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try await sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("<title>Screen Share</title>"))
        #expect(responseText.contains("/signal/7"))
        #expect(responseText.contains("Display 7") == false)
    }

    @Test func oversizedIncompleteSignalFrameClosesConnection() async throws {
        let sessionHub = TestSignalSessionHub()
        let setup = try await startMainSignalServer(sessionHub: sessionHub)
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }
        let result = try await Task.detached { try await probeOversizedFrameClose(port: portValue) }.value

        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.didClose)
    }

    @Test func clientCloseFrameLeavesNoGhostClientsInSharingSnapshot() async throws {
        let sessionHub = TestSignalSessionHub()
        let aggregator = SharingStateAggregator()
        let setup = try await startMainSignalServer(
            sessionHub: sessionHub,
            sharingEventSink: { event in
                Task { @MainActor in
                    aggregator.record(event)
                }
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let result = try await Task.detached { try await probeClientCloseFrame(port: portValue) }.value
        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.didClose)

        let clientCleared = await waitUntilAsync(timeout: .seconds(2)) {
            server.activeStreamClientCount == 0 &&
            sessionHub.activeClientCount == 0 &&
            aggregator.currentSnapshot.signalingConnections == 0 &&
            aggregator.currentSnapshot.streamingPeers == 0 &&
            aggregator.currentSnapshot.clientsByTarget[.id(Self.mainAliasShareID)]?.isEmpty ?? true
        }
        #expect(clientCleared)
    }

    @Test func sameTargetPeersAccumulateStreamingCounts() async throws {
        let aggregator = SharingStateAggregator()
        let sessionHub = TestSignalSessionHub()
        let setup = try await startMainSignalServer(
            sessionHub: sessionHub,
            sharingEventSink: { event in
                Task { @MainActor in
                    aggregator.record(event)
                }
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let firstSocket = try await openWebSocket(path: "/signal", port: portValue)
        let secondSocket = try await openWebSocket(path: "/signal", port: portValue)
        defer {
            close(firstSocket)
            close(secondSocket)
        }

        try sendAll(firstSocket, data: makeMaskedTextFrame(#"{"type":"offer","sdp":"v=0"}"#))
        try sendAll(secondSocket, data: makeMaskedTextFrame(#"{"type":"offer","sdp":"v=0"}"#))

        let accumulated = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnections == 2 &&
                snapshot.streamingPeers == 2 &&
                snapshot.signalingConnectionsByTarget[.id(Self.mainAliasShareID)] == 2 &&
                snapshot.streamingPeersByTarget[.id(Self.mainAliasShareID)] == 2
        }
        #expect(accumulated)

        try sendAll(firstSocket, data: makeMaskedCloseFrame())
        try sendAll(secondSocket, data: makeMaskedCloseFrame())
        #expect(try await waitForSocketClose(firstSocket))
        #expect(try await waitForSocketClose(secondSocket))

        let cleared = await waitUntilAsync(timeout: .seconds(2)) {
            aggregator.currentSnapshot.signalingConnections == 0 &&
            aggregator.currentSnapshot.streamingPeers == 0
        }
        #expect(cleared)
    }

    @Test func existingAliasConnectionKeepsBoundHubAfterMainMappingChanges() async throws {
        let aggregator = SharingStateAggregator()
        let sessionHub = TestSignalSessionHub()
        let mainShareIDBox = MutableShareIDBox(Self.mainAliasShareID)
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                switch target {
                case .main:
                    .active
                case .id(let id) where id == Self.mainAliasShareID || id == Self.replacementMainAliasShareID:
                    .active
                default:
                    .unknown
                }
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(mainShareIDBox.value)
                case .id(let id) where id == Self.mainAliasShareID || id == Self.replacementMainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                switch target {
                case .id(let id) where id == mainShareIDBox.value:
                    sessionHub
                default:
                    nil
                }
            },
            sharingEventSink: { event in
                Task { @MainActor in
                    aggregator.record(event)
                }
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let socket = try await openWebSocket(path: "/signal", port: portValue)
        defer { close(socket) }

        let connected = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnectionsByTarget[.id(Self.mainAliasShareID)] == 1 &&
                sessionHub.activeClientCount == 1
        }
        #expect(connected)

        mainShareIDBox.setValue(Self.replacementMainAliasShareID)

        try sendAll(socket, data: makeMaskedTextFrame(#"{"type":"offer","sdp":"v=0"}"#))

        let offerStillHandledByBoundHub = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.streamingPeersByTarget[.id(Self.mainAliasShareID)] == 1
        }
        #expect(offerStillHandledByBoundHub)

        try sendAll(socket, data: makeMaskedCloseFrame())
        #expect(try await waitForSocketClose(socket))

        let cleared = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnections == 0 &&
                snapshot.streamingPeers == 0 &&
                sessionHub.activeClientCount == 0
        }
        #expect(cleared)
    }

    @Test func targetedDisconnectRemovesOnlyMatchingConnections() async throws {
        let aggregator = SharingStateAggregator()
        let mainHub = TestSignalSessionHub()
        let secondaryHub = TestSignalSessionHub()
        let setup = try await startMainAndSecondarySignalServer(
            mainHub: mainHub,
            secondaryHub: secondaryHub,
            sharingEventSink: { event in
                Task { @MainActor in
                    aggregator.record(event)
                }
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let mainSocket = try await openWebSocket(path: "/signal", port: portValue)
        let secondarySocket = try await openWebSocket(path: "/signal/7", port: portValue)
        defer {
            close(mainSocket)
            close(secondarySocket)
        }

        try sendAll(mainSocket, data: makeMaskedTextFrame(#"{"type":"offer","sdp":"v=0"}"#))
        try sendAll(secondarySocket, data: makeMaskedTextFrame(#"{"type":"offer","sdp":"v=0"}"#))

        let connected = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnections == 2 &&
                snapshot.streamingPeers == 2 &&
                mainHub.activeClientCount == 1 &&
                secondaryHub.activeClientCount == 1
        }
        #expect(connected)

        server.disconnectStreamClients(for: [.id(Self.mainAliasShareID)])

        let mainClosed = try await waitForSocketClose(mainSocket)
        #expect(mainClosed)

        let targetedDisconnectObserved = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnections == 1 &&
                snapshot.streamingPeers == 1 &&
                snapshot.signalingConnectionsByTarget[.id(Self.mainAliasShareID)] == nil &&
                snapshot.streamingPeersByTarget[.id(Self.mainAliasShareID)] == nil &&
                snapshot.signalingConnectionsByTarget[.id(7)] == 1 &&
                snapshot.streamingPeersByTarget[.id(7)] == 1 &&
                mainHub.activeClientCount == 0 &&
                secondaryHub.activeClientCount == 1 &&
                server.streamClientCount(for: .id(Self.mainAliasShareID)) == 0 &&
                server.streamClientCount(for: .id(7)) == 1
        }
        #expect(targetedDisconnectObserved)

        try sendAll(secondarySocket, data: makeMaskedCloseFrame())
        #expect(try await waitForSocketClose(secondarySocket))
    }

    @Test func binarySignalFrameClosesWithProtocolCodeAndRemovesActiveClient() async throws {
        let sessionHub = TestSignalSessionHub()
        let setup = try await startMainSignalServer(sessionHub: sessionHub)
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let result = try await Task.detached { try await probeBinarySignalFrameClose(port: portValue) }.value
        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.closeObservation.didClose)
        #expect(result.closeObservation.closeCode == 1003)

        let clientCleared = await waitUntilAsync(timeout: .seconds(2)) {
            server.activeStreamClientCount == 0 && sessionHub.activeClientCount == 0
        }
        #expect(clientCleared)
    }

    private func startMainSignalServer(
        sessionHub: TestSignalSessionHub,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void = { _ in }
    ) async throws -> (server: WebServer, port: UInt16) {
        try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: Self.resolveMainAliasTarget,
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
            },
            sharingEventSink: sharingEventSink
        )
    }

    private static func resolveMainAliasTarget(_ target: ShareTarget) -> ShareTarget? {
        switch target {
        case .main:
            .id(mainAliasShareID)
        case .id(let id) where id == mainAliasShareID:
            .id(id)
        default:
            nil
        }
    }

    private func startMainAndSecondarySignalServer(
        mainHub: TestSignalSessionHub,
        secondaryHub: TestSignalSessionHub,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) async throws -> (server: WebServer, port: UInt16) {
        try await startServerOnRandomPort(
            targetStateProvider: { target in
                switch target {
                case .main, .id(7):
                    .active
                default:
                    .unknown
                }
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID || id == 7:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                switch target {
                case .id(let id) where id == Self.mainAliasShareID:
                    mainHub
                case .id(7):
                    secondaryHub
                default:
                    nil
                }
            },
            sharingEventSink: sharingEventSink
        )
    }

    private func waitUntilAsync(
        timeout: Duration,
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

    private func startReboundServer(on portValue: UInt16) async throws -> (server: WebServer, boundPort: UInt16) {
        let endpointPort = try #require(NWEndpoint.Port(rawValue: portValue))
        var lastError: Error = SocketIntegrationError.bindFailed
        for _ in 0..<10 {
            let server: WebServer
            do {
                server = try WebServer(
                    using: endpointPort,
                    targetStateProvider: { _ in .unknown },
                    concreteTargetResolver: { _ in nil },
                    sessionHubProvider: { _ in nil },
                    sharingEventSink: { _ in }
                )
            } catch {
                lastError = error
                if !Self.isAddressInUse(error) {
                    throw error
                }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }

            let startResult = await server.startListener(timeout: 1.0)
            switch startResult {
            case .ready(let boundPort):
                return (server, boundPort)
            case .failed(let error):
                server.stopListener()
                lastError = error
                if !Self.isAddressInUse(error) {
                    throw error
                }
                try? await Task.sleep(for: .milliseconds(50))
            case .timedOut:
                server.stopListener()
                lastError = SocketIntegrationError.receiveTimeout
            }
        }
        throw lastError
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if let nwError = error as? NWError,
           case .posix(let code) = nwError {
            return code == .EADDRINUSE
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain &&
            nsError.code == POSIXErrorCode.EADDRINUSE.rawValue
    }

    private func openWebSocket(path: String, port: UInt16) async throws -> Int32 {
        let result = try await Task.detached {
            let socketFD = try await connectLoopbackSocket(port: port)
            do {
                try sendAll(socketFD, data: websocketUpgradeRequest(path: path, port: port))
                let handshake = try readUntilHeaderTerminator(
                    from: socketFD,
                    timeoutMilliseconds: 500,
                    deadlineSeconds: 8
                )
                let terminator = Data("\r\n\r\n".utf8)
                guard let headerRange = handshake.range(of: terminator) else {
                    throw SocketIntegrationError.receiveFailed
                }
                let headerData = Data(handshake[..<headerRange.upperBound])
                guard let handshakeText = String(data: headerData, encoding: .utf8) else {
                    throw SocketIntegrationError.receiveFailed
                }
                return (socketFD, handshakeText)
            } catch {
                close(socketFD)
                throw error
            }
        }.value
        #expect(result.1.contains("101 Switching Protocols"))
        return result.0
    }

    private func waitForSocketClose(_ socketFD: Int32) async throws -> Bool {
        try await Task.detached {
            try waitForCloseOrEOF(from: socketFD, deadlineSeconds: 5)
        }.value
    }
}

private func displayPageRequiredSnippets(signalID: UInt32) -> [String] {
    [
        "HTTP/1.1 200 OK",
        "<title>Screen Share</title>",
        #"id="voiddisplay-bootstrap""#,
        #""iceServers":[{"urls":["stun:127.0.0.1:3478","turn:127.0.0.1:3479"]}]"#,
        #"const messages = {"#,
        #"document.title = t("pageTitle");"#,
        #"function receiverCodecPreferences() {"#,
        #"return normalizedVideoCodecName(codec) === "video/av1";"#,
        #"transceiver.setCodecPreferences(codecPreferences);"#,
        #"selectedCodecFromAnswerSDP(payload.sdp);"#,
        #"function setVideoInfo(text) {"#,
        #"function setConnectionStatus(title, detail = "") {"#,
        #"peer.addTransceiver("video", { direction: "recvonly" });"#,
        #"sdp: await waitForLocalOfferSDP()"#,
        #"const reconnectDelays = [250, 500, 1000, 2000, 4000];"#,
        #"function waitForFirstVideoFrame(timeoutMs = firstVideoFrameTimeoutMs) {"#,
        #"case "codec_pending":"#,
        #"connect();"#,
        #"heroEyebrow: "VOIDDISPLAY 实时画面""#,
        #"overlayCodecRequiredTitle: "AV1 required""#,
        #"overlayCodecRequiredTitle: "需要 AV1""#,
        #"overlayFirstFrameTimeoutTitle: "Waiting for video""#,
        #"overlayFirstFrameTimeoutTitle: "正在等待画面""#,
        #"fullscreenEnter: "全屏""#,
        #"pageTitle: "Screen Share""#,
        "hero-eyebrow",
        "video-info",
        "connection-status",
        "loading-spinner",
        "footnote",
        "/signal/\(signalID)"
    ]
}

private let displayPageForbiddenSnippets = [
    #"WebRTC receiver video capabilities "#,
    #"WebRTC browser stats"#,
    #"function initialForceH264Only() {"#,
    #"forceH264Only"#,
    #"function receiverSupportsCodec(mimeType) {"#,
    #"offerToReceiveVideo"#,
    #"function shouldRetryWithH264Fallback() {"#,
    #"function retryWithH264Fallback() {"#,
    #"sdp: offer.sdp"#,
    #"function setStartupOverlay() {"#,
    #"overlayStartupTitle"#,
    #"overlayCodecFallbackTitle"#,
    "message-title",
    "message-body",
    "__PAGE_TITLE__",
    "__SIGNAL_PATH__",
    "__DISPLAY_PAGE_STYLES__",
    "__DISPLAY_PAGE_MESSAGES_SCRIPT__",
    "__DISPLAY_PAGE_RUNTIME_SCRIPT__",
    #"new WebSocket((window.location.protocol === "https:" ? "wss://" : "ws://") + window.location.host + "/signal");"#,
    "Main Display",
    "Display 1"
]

@MainActor
private final class MutableShareIDBox {
    var value: UInt32

    init(_ value: UInt32) {
        self.value = value
    }

    func setValue(_ newValue: UInt32) {
        value = newValue
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
) async throws -> (handshakeText: String, didClose: Bool) {
    var lastError: Error = SocketIntegrationError.receiveFailed
    for attempt in 1...maxAttempts {
        do {
            let socketFD = try await connectLoopbackSocket(port: port)
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
                await Task.yield()
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
) async throws -> (handshakeText: String, didClose: Bool) {
    var lastError: Error = SocketIntegrationError.receiveFailed
    for attempt in 1...maxAttempts {
        do {
            let socketFD = try await connectLoopbackSocket(port: port)
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
                await Task.yield()
                continue
            }
        }
    }
    throw lastError
}

private func probeBinarySignalFrameClose(
    port: UInt16,
    maxAttempts: Int = 3
) async throws -> (handshakeText: String, closeObservation: WebSocketCloseObservation) {
    var lastError: Error = SocketIntegrationError.receiveFailed
    for attempt in 1...maxAttempts {
        do {
            let socketFD = try await connectLoopbackSocket(port: port)
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
                await Task.yield()
                continue
            }
        }
    }
    throw lastError
}
