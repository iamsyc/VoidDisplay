@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
import Foundation
import Darwin
import JavaScriptCore
import Testing

private final class IntegrationAutoConnectingPeer: @unchecked Sendable, WebRTCPeerSessioning {
    private let onConnected: @Sendable () -> Void

    init(onConnected: @escaping @Sendable () -> Void) {
        self.onConnected = onConnected
    }

    nonisolated func handleRemoteOffer(sdp _: String) {
        onConnected()
    }

    nonisolated func addRemoteCandidate(sdp _: String, sdpMid _: String?, sdpMLineIndex _: Int32) {}

    nonisolated func close() {}
}

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

    @Test func liveRouteUpgradesToWebSocketWhenTargetActive() async throws {
        let sessionHub = WebRTCSessionHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
            }
        )
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
            sessionHubProvider: { _ in WebRTCSessionHub() }
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

        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { _ in WebRTCSessionHub() }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /display HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try await sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("<title>Screen Share</title>"))
        #expect(responseText.contains(#"id="voiddisplay-bootstrap""#))
        #expect(responseText.contains(#""iceServers":[{"urls":["stun:127.0.0.1:3478","turn:127.0.0.1:3479"]}]"#))
        #expect(responseText.contains(#"const messages = {"#))
        #expect(responseText.contains(#"function resolveLocale() {"#))
        #expect(responseText.contains(#"const locale = resolveLocale();"#))
        #expect(responseText.contains(#"document.title = t("pageTitle");"#))
        #expect(responseText.contains(#"function applyScaleMode() {"#))
        #expect(responseText.contains(#"function syncFullscreenButtonLabel() {"#))
        #expect(responseText.contains(#"const reconnectDelays = [250, 500, 1000, 2000, 4000];"#))
        #expect(responseText.contains(#"function scheduleReconnect() {"#))
        #expect(responseText.contains(#"peer = new RTCPeerConnection({ iceServers: bootstrap.iceServers ?? [] });"#))
        #expect(responseText.contains(#"setOverlay(t("overlayReconnectTitle"), t("overlayReconnectBody"), true);"#))
        #expect(responseText.contains(#"setOverlay(t("overlaySharingStoppedTitle"), t("overlaySharingStoppedBody"), true);"#))
        #expect(responseText.contains(#"case "stopped":"#))
        #expect(responseText.contains(#"case "error":"#))
        #expect(responseText.contains(#"connect();"#))
        #expect(responseText.contains(#"heroEyebrow: "VOIDDISPLAY 实时画面""#))
        #expect(responseText.contains(#"fullscreenEnter: "全屏""#))
        #expect(responseText.contains(#"pageTitle: "Screen Share""#))
        #expect(responseText.contains("hero-eyebrow"))
        #expect(responseText.contains("footnote"))
        #expect(responseText.contains("__PAGE_TITLE__") == false)
        #expect(responseText.contains("__SIGNAL_PATH__") == false)
        #expect(responseText.contains("/signal/\(Self.mainAliasShareID)"))
        #expect(responseText.contains(#"new WebSocket((window.location.protocol === "https:" ? "wss://" : "ws://") + window.location.host + "/signal");"#) == false)
        #expect(responseText.contains("Main Display") == false)
        #expect(responseText.contains("Display 1") == false)
    }

    @Test func secondaryDisplayRouteAlsoUsesGenericPageTitle() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            sessionHubProvider: { _ in WebRTCSessionHub() }
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

    @Test func displayRouteScriptBootstrapsAndHandlesBasicUIStateChanges() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .active },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { _ in WebRTCSessionHub() }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let request = Data("GET /display HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try await sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("/signal/\(Self.mainAliasShareID)"))
        let smokeResult = try evaluateDisplayPageRuntimeScript(in: responseText)

        #expect(smokeResult.documentTitle == "Screen Share")
        #expect(smokeResult.scaleButtonText == "Fit")
        #expect(smokeResult.toggleCallCount >= 2)
    }

    @Test func oversizedIncompleteSignalFrameClosesConnection() async throws {
        let sessionHub = WebRTCSessionHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }
        let result = try await Task.detached { try await probeOversizedFrameClose(port: portValue) }.value

        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.didClose)
    }

    @Test func clientCloseFrameRemovesActiveClient() async throws {
        let sessionHub = WebRTCSessionHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let result = try await Task.detached { try await probeClientCloseFrame(port: portValue) }.value
        #expect(result.handshakeText.contains("101 Switching Protocols"))
        #expect(result.didClose)

        let clientCleared = await waitUntilAsync(timeout: .seconds(2)) {
            server.activeStreamClientCount == 0 && sessionHub.activeClientCount == 0
        }
        #expect(clientCleared)
    }

    @Test func clientCloseFrameLeavesNoGhostClientsInSharingSnapshot() async throws {
        let sessionHub = WebRTCSessionHub()
        let aggregator = SharingStateAggregator()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
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
        let sessionHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
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
        _ = try await waitForSocketClose(firstSocket)
        _ = try await waitForSocketClose(secondSocket)

        let cleared = await waitUntilAsync(timeout: .seconds(2)) {
            aggregator.currentSnapshot.signalingConnections == 0 &&
            aggregator.currentSnapshot.streamingPeers == 0
        }
        #expect(cleared)
    }

    @Test func simultaneousTargetsKeepPerTargetSharingCountsIsolated() async throws {
        let aggregator = SharingStateAggregator()
        let mainHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let secondaryHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let setup = try await startServerOnRandomPort(
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

        let isolated = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnections == 2 &&
                snapshot.streamingPeers == 2 &&
                snapshot.signalingConnectionsByTarget[.id(Self.mainAliasShareID)] == 1 &&
                snapshot.signalingConnectionsByTarget[.id(7)] == 1 &&
                snapshot.streamingPeersByTarget[.id(Self.mainAliasShareID)] == 1 &&
                snapshot.streamingPeersByTarget[.id(7)] == 1 &&
                server.streamClientCount(for: .id(Self.mainAliasShareID)) == 1 &&
                server.streamClientCount(for: .id(7)) == 1
        }
        #expect(isolated)
    }

    @Test func aliasConnectionCleanupStaysBoundToOriginalConcreteTargetAfterMainSwitch() async throws {
        let aggregator = SharingStateAggregator()
        let originalHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let replacementHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
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
                case .id(let id) where id == Self.mainAliasShareID:
                    originalHub
                case .id(let id) where id == Self.replacementMainAliasShareID:
                    replacementHub
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

        try sendAll(socket, data: makeMaskedTextFrame(#"{"type":"offer","sdp":"v=0"}"#))

        let connectedToOriginalTarget = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnectionsByTarget[.id(Self.mainAliasShareID)] == 1 &&
                snapshot.streamingPeersByTarget[.id(Self.mainAliasShareID)] == 1 &&
                originalHub.activeClientCount == 1 &&
                replacementHub.activeClientCount == 0
        }
        #expect(connectedToOriginalTarget)

        mainShareIDBox.setValue(Self.replacementMainAliasShareID)

        try sendAll(socket, data: makeMaskedCloseFrame())
        _ = try await waitForSocketClose(socket)

        let clearedFromOriginalTarget = await waitUntilAsync(timeout: .seconds(2)) {
            let snapshot = aggregator.currentSnapshot
            return snapshot.signalingConnections == 0 &&
                snapshot.streamingPeers == 0 &&
                snapshot.signalingConnectionsByTarget[.id(Self.mainAliasShareID)] == nil &&
                snapshot.streamingPeersByTarget[.id(Self.mainAliasShareID)] == nil &&
                originalHub.activeClientCount == 0 &&
                replacementHub.activeClientCount == 0
        }
        #expect(clearedFromOriginalTarget)
    }

    @Test func existingAliasConnectionKeepsBoundHubAfterMainMappingChanges() async throws {
        let aggregator = SharingStateAggregator()
        let sessionHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
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
        _ = try await waitForSocketClose(socket)

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
        let mainHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let secondaryHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let setup = try await startServerOnRandomPort(
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
        _ = try await waitForSocketClose(secondarySocket)
    }

    @Test func tenClientsOnSameTargetCanConnectAndDisconnectCleanly() async throws {
        let sessionHub = WebRTCSessionHub(
            peerFactory: { callbacks in
                IntegrationAutoConnectingPeer(onConnected: callbacks.onConnected)
            }
        )
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer { server.stopListener() }

        let expectedClientCount = 10
        var sockets: [Int32] = []
        sockets.reserveCapacity(expectedClientCount)
        do {
            for _ in 0..<expectedClientCount {
                let socket = try await openWebSocket(path: "/signal", port: portValue)
                sockets.append(socket)
            }
        } catch {
            for socket in sockets {
                close(socket)
            }
            throw error
        }
        defer {
            for socket in sockets {
                close(socket)
            }
        }

        let connected = await waitUntilAsync(timeout: .seconds(4)) {
            server.activeStreamClientCount == expectedClientCount &&
                sessionHub.activeClientCount == expectedClientCount &&
                server.streamClientCount(for: .id(Self.mainAliasShareID)) == expectedClientCount
        }
        #expect(connected)

        for socket in sockets {
            try sendAll(socket, data: makeMaskedCloseFrame())
        }
        for socket in sockets {
            _ = try await waitForSocketClose(socket)
        }

        let cleared = await waitUntilAsync(timeout: .seconds(4)) {
            server.activeStreamClientCount == 0 &&
                sessionHub.activeClientCount == 0 &&
                server.streamClientCount(for: .id(Self.mainAliasShareID)) == 0
        }
        #expect(cleared)
    }

    @Test func binarySignalFrameClosesWithProtocolCodeAndRemovesActiveClient() async throws {
        let sessionHub = WebRTCSessionHub()
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            concreteTargetResolver: { target in
                switch target {
                case .main:
                    .id(Self.mainAliasShareID)
                case .id(let id) where id == Self.mainAliasShareID:
                    .id(id)
                default:
                    nil
                }
            },
            sessionHubProvider: { target in
                target == .id(Self.mainAliasShareID) ? sessionHub : nil
            }
        )
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

private struct DisplayPageScriptSmokeResult: Equatable {
    let documentTitle: String
    let scaleButtonText: String
    let toggleCallCount: Int
}

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

private enum DisplayPageScriptSmokeError: Error {
    case missingRuntimeScript
    case evaluationFailed(String)
}

private func evaluateDisplayPageRuntimeScript(
    in responseText: String
) throws -> DisplayPageScriptSmokeResult {
    guard let scriptOpenRange = responseText.range(of: "<script>", options: .backwards),
          let scriptCloseRange = responseText.range(
              of: "</script>",
              range: scriptOpenRange.upperBound..<responseText.endIndex
          ) else {
        throw DisplayPageScriptSmokeError.missingRuntimeScript
    }

    let script = String(responseText[scriptOpenRange.upperBound..<scriptCloseRange.lowerBound])
    let context = JSContext()!
    var exceptionMessage: String?
    context.exceptionHandler = { _, exception in
        exceptionMessage = exception?.toString() ?? "unknown JavaScript error"
    }

    context.evaluateScript(
        """
        var __toggleCount = 0;
        var __elements = {};

        function makeElement(id) {
            return {
                id: id,
                textContent: "",
                hidden: false,
                srcObject: null,
                __handlers: {},
                addEventListener: function(type, handler) {
                    this.__handlers[type] = handler;
                },
                classList: {
                    toggle: function() {
                        __toggleCount += 1;
                    }
                },
                requestFullscreen: function() {}
            };
        }

        function WebSocket(url) {
            this.url = url;
            this.__handlers = {};
        }
        WebSocket.prototype.addEventListener = function(type, handler) {
            this.__handlers[type] = handler;
        };
        WebSocket.prototype.send = function() {};
        WebSocket.prototype.close = function() {};

        function RTCPeerConnection(config) {
            this.config = config;
        }
        RTCPeerConnection.prototype.addIceCandidate = function() {};
        RTCPeerConnection.prototype.close = function() {};

        var document = {
            title: "",
            fullscreenElement: null,
            fullscreenEnabled: false,
            body: {
                classList: {
                    toggle: function() {
                        __toggleCount += 1;
                    }
                }
            },
            getElementById: function(id) {
                if (!__elements[id]) {
                    __elements[id] = makeElement(id);
                }
                return __elements[id];
            },
            querySelector: function() {
                return makeElement("stage");
            },
            addEventListener: function(type, handler) {
                this["on" + type] = handler;
            },
            exitFullscreen: function() {}
        };

        var navigator = {
            languages: ["en-US"],
            language: "en-US"
        };

        var window = {
            WebSocket: WebSocket,
            RTCPeerConnection: RTCPeerConnection,
            location: {
                protocol: "http:",
                host: "127.0.0.1"
            },
            setTimeout: function() { return 1; },
            clearTimeout: function() {},
            addEventListener: function() {}
        };

        var console = {
            log: function() {},
            warn: function() {},
            error: function() {}
        };
        """
    )
    if let exceptionMessage {
        throw DisplayPageScriptSmokeError.evaluationFailed(exceptionMessage)
    }

    context.evaluateScript(script)
    if let exceptionMessage {
        throw DisplayPageScriptSmokeError.evaluationFailed(exceptionMessage)
    }

    context.evaluateScript(
        """
        transition("streaming");
        __elements["scale-mode-btn"].__handlers["click"]();
        """
    )
    if let exceptionMessage {
        throw DisplayPageScriptSmokeError.evaluationFailed(exceptionMessage)
    }

    let documentTitle = context.evaluateScript("document.title")?.toString() ?? ""
    let scaleButtonText = context.evaluateScript("__elements['scale-mode-btn'].textContent")?.toString() ?? ""
    let toggleCallCount = Int(context.evaluateScript("__toggleCount")?.toInt32() ?? 0)
    return DisplayPageScriptSmokeResult(
        documentTitle: documentTitle,
        scaleButtonText: scaleButtonText,
        toggleCallCount: toggleCallCount
    )
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
