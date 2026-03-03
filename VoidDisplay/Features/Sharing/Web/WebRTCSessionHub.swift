import CoreVideo
import Foundation
import Network
import Synchronization

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

protocol SignalSocketConnection: AnyObject {
    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void)
    nonisolated func cancelSocket()
}

extension NWConnection: SignalSocketConnection {
    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(content: content, completion: .contentProcessed(completion))
    }

    nonisolated func cancelSocket() {
        cancel()
    }
}

protocol WebRTCPeerSessioning: AnyObject, Sendable {
    nonisolated func handleRemoteOffer(sdp: String)
    nonisolated func addRemoteCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32)
    nonisolated func close()
}

nonisolated private enum SignalingMessageType: String, Codable {
    case viewerReady = "viewer_ready"
    case offer
    case answer
    case iceCandidate = "ice_candidate"
    case iceComplete = "ice_complete"
    case ready
    case stopped
    case error
}

nonisolated private struct SignalingInboundMessage: Decodable {
    let type: String?
    let sdp: String?
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

nonisolated private struct SignalingOutboundMessage: Encodable {
    let type: SignalingMessageType
    let reason: String?
    let sdp: String?
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int?

    init(
        type: SignalingMessageType,
        reason: String? = nil,
        sdp: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int? = nil
    ) {
        self.type = type
        self.reason = reason
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

final class WebRTCSessionHub: Sendable {
    nonisolated struct PeerCallbacks: Sendable {
        let onAnswer: @Sendable (String) -> Void
        let onLocalCandidate: @Sendable (_ sdp: String, _ sdpMid: String?, _ sdpMLineIndex: Int32) -> Void
        let onFailure: @Sendable (String) -> Void
        let onDisconnected: @Sendable () -> Void
    }

    typealias PeerFactory = @Sendable (PeerCallbacks) -> (any WebRTCPeerSessioning)?

    private nonisolated struct QueuedSignal: Sendable {
        let text: String
        let disconnectAfterSend: Bool
    }

    private nonisolated struct ClientState {
        nonisolated(unsafe) let connection: any SignalSocketConnection
        var isSending = false
        var pendingSignals: [QueuedSignal] = []
        var peer: (any WebRTCPeerSessioning)?
    }

    private nonisolated struct State: ~Copyable {
        var clients: [ObjectIdentifier: ClientState] = [:]
        var onDemandChanged: @Sendable (Bool) -> Void
    }

    nonisolated private let state: Mutex<State>
    nonisolated private let maxClients = 10
    nonisolated private let peerFactory: PeerFactory

#if canImport(WebRTC)
    nonisolated private let mediaPipeline = WebRTCMediaPipeline()
#endif

    nonisolated init(
        onDemandChanged: @escaping @Sendable (Bool) -> Void = { _ in },
        peerFactory: PeerFactory? = nil
    ) {
        self.state = Mutex(State(onDemandChanged: onDemandChanged))
#if canImport(WebRTC)
        let defaultPeerFactory: PeerFactory = { [mediaPipeline] callbacks in
            WebRTCPeerSession(
                mediaPipeline: mediaPipeline,
                onAnswer: callbacks.onAnswer,
                onLocalCandidate: { candidate in
                    callbacks.onLocalCandidate(
                        candidate.sdp,
                        candidate.sdpMid,
                        Int32(candidate.sdpMLineIndex)
                    )
                },
                onFailure: callbacks.onFailure,
                onDisconnected: callbacks.onDisconnected
            )
        }
        self.peerFactory = peerFactory ?? defaultPeerFactory
#else
        self.peerFactory = peerFactory ?? { _ in nil }
#endif
    }

    nonisolated var activeClientCount: Int {
        state.withLock { $0.clients.count }
    }

    nonisolated var hasDemand: Bool {
        activeClientCount > 0
    }

    nonisolated func updateDemandHandler(_ onDemandChanged: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.onDemandChanged = onDemandChanged }
    }

    nonisolated func addClient(_ connection: any SignalSocketConnection) {
        let key = ObjectIdentifier(connection as AnyObject)
        let (added, shouldSignalDemand, callback) = state.withLock { state -> (Bool, Bool, @Sendable (Bool) -> Void) in
            guard state.clients.count < maxClients else {
                return (false, false, state.onDemandChanged)
            }
            let wasEmpty = state.clients.isEmpty
            state.clients[key] = ClientState(connection: connection)
            return (true, wasEmpty, state.onDemandChanged)
        }

        if !added {
            send(
                message: SignalingOutboundMessage(type: .error, reason: "too_many_viewers"),
                to: connection,
                completion: nil
            )
            connection.cancelSocket()
            return
        }

        if shouldSignalDemand {
            callback(true)
        }

        send(message: SignalingOutboundMessage(type: .ready), to: connection, completion: nil)
    }

    nonisolated func removeClient(_ connection: any SignalSocketConnection) {
        removeClient(for: ObjectIdentifier(connection as AnyObject), cancelConnection: false)
    }

    nonisolated func disconnectAllClients() {
        let keys = state.withLock { Array($0.clients.keys) }
        for key in keys {
            removeClient(for: key, cancelConnection: true)
        }
    }

    nonisolated func stopSharing() {
        let keys = state.withLock { Array($0.clients.keys) }
        for key in keys {
            enqueue(
                message: SignalingOutboundMessage(type: .stopped),
                to: key,
                disconnectAfterSend: true,
                replacePending: true
            )
        }
    }

    nonisolated func receiveSignalText(_ text: String, from connection: any SignalSocketConnection) {
        let key = ObjectIdentifier(connection as AnyObject)
        guard let message = parseMessage(text) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "invalid_signal_payload"), to: key)
            return
        }
        guard let typeRawValue = message.type else {
            send(message: SignalingOutboundMessage(type: .error, reason: "missing_signal_type"), to: key)
            return
        }
        guard let type = SignalingMessageType(rawValue: typeRawValue) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: key)
            return
        }
        handle(message: message, type: type, for: key)
    }

    nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        guard hasDemand else { return }
#if canImport(WebRTC)
        mediaPipeline.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
#else
        _ = pixelBuffer
        _ = ptsUs
#endif
    }

    nonisolated private func handle(
        message: SignalingInboundMessage,
        type: SignalingMessageType,
        for key: ObjectIdentifier
    ) {
        switch type {
        case .viewerReady:
            return
        case .offer:
            guard let sdp = message.sdp else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_offer_sdp"), to: key)
                return
            }
            ensurePeer(for: key)?.handleRemoteOffer(sdp: sdp)
        case .iceCandidate:
            guard let candidate = message.candidate else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_ice_candidate"), to: key)
                return
            }
            let lineIndexValue = Int32(message.sdpMLineIndex ?? 0)
            ensurePeer(for: key)?.addRemoteCandidate(
                sdp: candidate,
                sdpMid: message.sdpMid,
                sdpMLineIndex: lineIndexValue
            )
        case .iceComplete:
            return
        default:
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: key)
        }
    }

    nonisolated private func ensurePeer(for key: ObjectIdentifier) -> (any WebRTCPeerSessioning)? {
        let (hasClient, existingPeer) = state.withLock { state -> (Bool, (any WebRTCPeerSessioning)?) in
            guard let current = state.clients[key] else { return (false, nil) }
            return (true, current.peer)
        }
        guard hasClient else { return nil }
        if let existingPeer { return existingPeer }

#if canImport(WebRTC)
        let callbacks = PeerCallbacks(
            onAnswer: { [weak self] sdp in
                self?.send(message: SignalingOutboundMessage(type: .answer, sdp: sdp), to: key)
            },
            onLocalCandidate: { [weak self] sdp, sdpMid, sdpMLineIndex in
                self?.send(
                    message: SignalingOutboundMessage(
                        type: .iceCandidate,
                        candidate: sdp,
                        sdpMid: sdpMid,
                        sdpMLineIndex: Int(sdpMLineIndex)
                    ),
                    to: key
                )
            },
            onFailure: { [weak self] reason in
                self?.send(message: SignalingOutboundMessage(type: .error, reason: reason), to: key)
                self?.removeClient(for: key, cancelConnection: true)
            },
            onDisconnected: { [weak self] in
                self?.removeClient(for: key, cancelConnection: true)
            }
        )

        guard let peer = peerFactory(callbacks) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "peer_connection_unavailable"), to: key)
            removeClient(for: key, cancelConnection: true)
            return nil
        }

        let stored = state.withLock { state -> Bool in
            guard var current = state.clients[key] else { return false }
            current.peer = peer
            state.clients[key] = current
            return true
        }
        guard stored else {
            peer.close()
            return nil
        }
        return peer
#else
        send(message: SignalingOutboundMessage(type: .error, reason: "server_webrtc_unavailable"), to: key)
        removeClient(for: key, cancelConnection: true)
        return nil
#endif
    }

    nonisolated private func parseMessage(_ text: String) -> SignalingInboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SignalingInboundMessage.self, from: data)
    }

    nonisolated private func encode(_ message: SignalingOutboundMessage) -> String? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private func send(
        message: SignalingOutboundMessage,
        to connection: any SignalSocketConnection,
        completion: (@Sendable (Error?) -> Void)?
    ) {
        guard let text = encode(message) else {
            completion?(nil)
            return
        }
        connection.sendSocketFrame(encodeWebSocketTextFrame(text)) { error in
            completion?(error)
        }
    }

    nonisolated private func send(message: SignalingOutboundMessage, to key: ObjectIdentifier) {
        enqueue(message: message, to: key, disconnectAfterSend: false, replacePending: false)
    }

    nonisolated private func enqueue(
        message: SignalingOutboundMessage,
        to key: ObjectIdentifier,
        disconnectAfterSend: Bool,
        replacePending: Bool
    ) {
        guard let text = encode(message) else {
            if disconnectAfterSend {
                removeClient(for: key, cancelConnection: true)
            }
            return
        }

        let connection = state.withLock { $0.clients[key]?.connection }
        guard let connection else { return }
        enqueue(
            text: text,
            to: key,
            connection: connection,
            disconnectAfterSend: disconnectAfterSend,
            replacePending: replacePending
        )
    }

    nonisolated private func enqueue(
        text: String,
        to key: ObjectIdentifier,
        connection: any SignalSocketConnection,
        disconnectAfterSend: Bool,
        replacePending: Bool
    ) {
        let queuedSignal = QueuedSignal(
            text: text,
            disconnectAfterSend: disconnectAfterSend
        )

        let nextToSend = state.withLock { state -> QueuedSignal? in
            guard var current = state.clients[key] else { return nil }
            if current.isSending {
                if replacePending {
                    current.pendingSignals = [queuedSignal]
                } else {
                    current.pendingSignals.append(queuedSignal)
                }
                state.clients[key] = current
                return nil
            }
            current.isSending = true
            state.clients[key] = current
            return queuedSignal
        }

        guard let nextToSend else { return }
        send(signal: nextToSend, to: key, connection: connection)
    }

    nonisolated private func send(
        signal: QueuedSignal,
        to key: ObjectIdentifier,
        connection: any SignalSocketConnection
    ) {
        connection.sendSocketFrame(encodeWebSocketTextFrame(signal.text)) { [weak self] error in
            guard let self else { return }
            if let error {
                AppErrorMapper.logFailure("Send WebRTC signaling message", error: error, logger: AppLog.web)
                self.removeClient(for: key, cancelConnection: true)
                return
            }

            if signal.disconnectAfterSend {
                self.removeClient(for: key, cancelConnection: true)
                return
            }

            let nextSignal = self.state.withLock { state -> QueuedSignal? in
                guard var current = state.clients[key] else { return nil }
                if current.pendingSignals.isEmpty {
                    current.isSending = false
                    state.clients[key] = current
                    return nil
                }
                let pending = current.pendingSignals.removeFirst()
                state.clients[key] = current
                return pending
            }

            guard let nextSignal else { return }
            guard let nextConnection = self.state.withLock({ $0.clients[key]?.connection }) else { return }
            self.send(signal: nextSignal, to: key, connection: nextConnection)
        }
    }

    nonisolated private func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
        let (removed, shouldSignalDemandOff, callback) = state.withLock { state -> (ClientState?, Bool, @Sendable (Bool) -> Void) in
            let removed = state.clients.removeValue(forKey: key)
            return (removed, state.clients.isEmpty, state.onDemandChanged)
        }

        guard let removed else { return }
        removed.peer?.close()
        if cancelConnection {
            removed.connection.cancelSocket()
        }
        if shouldSignalDemandOff {
            callback(false)
        }
    }
}

#if canImport(WebRTC)

private enum WebRTCIceServerProvider {
    // Reserved extension point: defaults to host candidates only for LAN P2P.
    nonisolated static func configuredServers() -> [RTCIceServer] {
        guard let raw = ProcessInfo.processInfo.environment["VOIDDISPLAY_WEBRTC_ICE_SERVERS"] else {
            return []
        }
        let urls = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return [] }
        return [RTCIceServer(urlStrings: urls)]
    }
}

private final class WebRTCMediaPipeline: @unchecked Sendable {
    private nonisolated struct SendablePixelBuffer: @unchecked Sendable {
        nonisolated(unsafe) let value: CVPixelBuffer

        nonisolated init(value: CVPixelBuffer) {
            self.value = value
        }
    }

    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    nonisolated(unsafe) let videoSource: RTCVideoSource
    nonisolated(unsafe) let videoTrack: RTCVideoTrack
    nonisolated(unsafe) private let capturer: RTCVideoCapturer
    private let queue = DispatchQueue(
        label: "com.developerchen.voiddisplay.webrtc.media",
        qos: .userInitiated
    )
    nonisolated(unsafe) private var lastFormat: (width: Int32, height: Int32)?

    nonisolated init() {
        self.videoSource = Self.factory.videoSource()
        self.videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "screen-video-track")
        self.capturer = RTCVideoCapturer(delegate: videoSource)
    }

    nonisolated static func makePeerConnection() -> RTCPeerConnection? {
        let configuration = RTCConfiguration()
        configuration.iceServers = WebRTCIceServerProvider.configuredServers()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        return factory.peerConnection(with: configuration, constraints: constraints, delegate: nil)
    }

    nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        let sendablePixelBuffer = SendablePixelBuffer(value: pixelBuffer)
        queue.async { [weak self, sendablePixelBuffer] in
            guard let self else { return }
            let pixelBuffer = sendablePixelBuffer.value
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            if self.lastFormat?.width != width || self.lastFormat?.height != height {
                self.videoSource.adaptOutputFormat(toWidth: width, height: height, fps: 60)
                self.lastFormat = (width, height)
            }

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(
                buffer: rtcBuffer,
                rotation: ._0,
                timeStampNs: Int64(ptsUs) * 1_000
            )
            self.videoSource.capturer(self.capturer, didCapture: frame)
        }
    }
}

private final class WebRTCPeerSession: NSObject, @unchecked Sendable, WebRTCPeerSessioning {
    nonisolated private static let desktopMinBitrateBps = NSNumber(value: 2_000_000)
    nonisolated private static let desktopMaxBitrateBps = NSNumber(value: 24_000_000)
    nonisolated private static let desktopMaxFramerate = NSNumber(value: 30)
    nonisolated private static let maintainResolutionPreference = NSNumber(
        value: RTCDegradationPreference.maintainResolution.rawValue
    )

    nonisolated(unsafe) private let peerConnection: RTCPeerConnection
    private let onAnswer: @Sendable (String) -> Void
    private let onLocalCandidate: @Sendable (RTCIceCandidate) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onDisconnected: @Sendable () -> Void

    nonisolated init?(
        mediaPipeline: WebRTCMediaPipeline,
        onAnswer: @escaping @Sendable (String) -> Void,
        onLocalCandidate: @escaping @Sendable (RTCIceCandidate) -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onDisconnected: @escaping @Sendable () -> Void
    ) {
        guard let peerConnection = WebRTCMediaPipeline.makePeerConnection() else { return nil }
        self.peerConnection = peerConnection
        self.onAnswer = onAnswer
        self.onLocalCandidate = onLocalCandidate
        self.onFailure = onFailure
        self.onDisconnected = onDisconnected
        super.init()
        self.peerConnection.delegate = self
        let sender = self.peerConnection.add(mediaPipeline.videoTrack, streamIds: ["screen"])
        configureDesktopVideoSender(sender)
        _ = self.peerConnection.setBweMinBitrateBps(
            Self.desktopMinBitrateBps,
            currentBitrateBps: nil,
            maxBitrateBps: Self.desktopMaxBitrateBps
        )
    }

    nonisolated private func configureDesktopVideoSender(_ sender: RTCRtpSender?) {
        guard let sender else { return }
        let parameters = sender.parameters
        if parameters.encodings.isEmpty {
            parameters.encodings = [RTCRtpEncodingParameters()]
        }
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = Self.desktopMaxBitrateBps
            encoding.minBitrateBps = Self.desktopMinBitrateBps
            encoding.maxFramerate = Self.desktopMaxFramerate
            encoding.scaleResolutionDownBy = NSNumber(value: 1.0)
            encoding.bitratePriority = 4.0
        }
        parameters.degradationPreference = Self.maintainResolutionPreference
        sender.parameters = parameters
    }

    nonisolated func handleRemoteOffer(sdp: String) {
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        peerConnection.setRemoteDescription(offer) { [weak self] error in
            guard let self else { return }
            if let error {
                self.onFailure("set_remote_description_failed: \(error.localizedDescription)")
                return
            }

            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.peerConnection.answer(for: constraints) { answer, error in
                guard let answer else {
                    self.onFailure("create_answer_failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                self.peerConnection.setLocalDescription(answer) { error in
                    if let error {
                        self.onFailure("set_local_description_failed: \(error.localizedDescription)")
                        return
                    }
                    self.onAnswer(answer.sdp)
                }
            }
        }
    }

    nonisolated func addRemoteCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnection.add(candidate) { [weak self] error in
            guard let self, let error else { return }
            self.onFailure("add_ice_candidate_failed: \(error.localizedDescription)")
        }
    }

    nonisolated func close() {
        peerConnection.close()
    }
}

extension WebRTCPeerSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .failed || newState == .closed || newState == .disconnected {
            onDisconnected()
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed || newState == .disconnected {
            onDisconnected()
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate(candidate)
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate candidate: RTCIceCandidate) {
        onLocalCandidate(candidate)
    }
}

#endif
