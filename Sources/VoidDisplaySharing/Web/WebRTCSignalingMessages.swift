import CoreVideo
import Foundation
import Network
import Synchronization
import VoidDisplayFoundation
import VoidDisplayObservability

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
package protocol SignalSocketConnection: AnyObject {
    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void)
    nonisolated func cancelSocket()
}

extension NWConnection: SignalSocketConnection {
    package nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(content: content, completion: .contentProcessed(completion))
    }

    package nonisolated func cancelSocket() {
        cancel()
    }
}

package enum SignalingMessageType: String, Codable {
    case viewerReady = "viewer_ready"
    case offer
    case answer
    case iceCandidate = "ice_candidate"
    case iceComplete = "ice_complete"
    case ready
    case codecPending = "codec_pending"
    case stopped
    case error
}

package struct SignalingInboundMessage: Decodable {
    package let type: String?
    package let sdp: String?
    package let candidate: String?
    package let sdpMid: String?
    package let sdpMLineIndex: Int?
}

package struct SourceVideoSpecSignalPayload: Codable, Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let framesPerSecond: Int

    package init(spec: SourceVideoSpec) {
        self.width = spec.dimensions.width
        self.height = spec.dimensions.height
        self.framesPerSecond = spec.framesPerSecond
    }
}

package struct SignalingOutboundMessage: Encodable {
    package let type: SignalingMessageType
    package let reason: String?
    package let sdp: String?
    package let candidate: String?
    package let sdpMid: String?
    package let sdpMLineIndex: Int?
    package let sourceVideoSpec: SourceVideoSpecSignalPayload?

    package init(
        type: SignalingMessageType,
        reason: String? = nil,
        sdp: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int? = nil,
        sourceVideoSpec: SourceVideoSpecSignalPayload? = nil
    ) {
        self.type = type
        self.reason = reason
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.sourceVideoSpec = sourceVideoSpec
    }
}
