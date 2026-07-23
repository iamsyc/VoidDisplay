import CoreVideo
import Foundation
import Network
import Synchronization
import VoidDisplayFoundation
import VoidDisplayObservability

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
package enum WebRTCIceServerProvider {
    nonisolated static func configuredURLStrings() -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["VOIDDISPLAY_WEBRTC_ICE_SERVERS"] else {
            return []
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func browserBootstrapJSON() -> String {
        let urls = configuredURLStrings()
        let payload: [String: Any] = [
            "iceServers": urls.isEmpty ? [] : [["urls": urls]]
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var json = String(data: data, encoding: .utf8) else {
            return #"{"iceServers":[]}"#
        }
        json = json.replacingOccurrences(of: "</script>", with: "<\\/script>")
        return json
    }
}

#if canImport(WebRTC)
extension WebRTCIceServerProvider {
    nonisolated static func configuredServers() -> [RTCIceServer] {
        let urls = configuredURLStrings()
        guard !urls.isEmpty else { return [] }
        return [RTCIceServer(urlStrings: urls)]
    }
}

package struct WebRTCCodecPreferenceDescriptor: Sendable, Equatable {
    package let name: String
    package let payloadType: Int?
    package let parameters: [String: String]

    package init(
        name: String,
        payloadType: Int?,
        parameters: [String: String]
    ) {
        self.name = name
        self.payloadType = payloadType
        self.parameters = parameters
    }
}

extension WebRTCVideoCodec {
    package var codecName: String {
        switch self {
        case .av1:
            "AV1"
        }
    }
}

package enum WebRTCCodecPreference {
    package nonisolated static func requiredDescriptorIndexes(
        for codec: WebRTCVideoCodec,
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> [Int]? {
        let primaryIndexes = descriptors.indices.filter {
            descriptors[$0].name.caseInsensitiveCompare(codec.codecName) == .orderedSame
        }
        guard !primaryIndexes.isEmpty else { return nil }

        let primaryPayloadTypes = Set(primaryIndexes.compactMap { descriptors[$0].payloadType })
        let rtxIndexes = descriptors.indices.filter { index in
            let descriptor = descriptors[index]
            guard descriptor.name.caseInsensitiveCompare(kRTCRtxCodecName) == .orderedSame,
                  let apt = descriptor.parameters["apt"].flatMap(Int.init) else {
                return false
            }
            return primaryPayloadTypes.contains(apt)
        }
        return primaryIndexes + rtxIndexes
    }

    package nonisolated static func requiredCodecs(
        for codec: WebRTCVideoCodec,
        from codecs: [RTCRtpCodecCapability]
    ) -> [RTCRtpCodecCapability]? {
        let descriptors = codecs.map {
            WebRTCCodecPreferenceDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                parameters: $0.parameters
            )
        }
        guard let indexes = requiredDescriptorIndexes(for: codec, from: descriptors) else {
            return nil
        }
        return indexes.map { codecs[$0] }
    }

    package nonisolated static func capabilitySummary(
        from codecs: [RTCRtpCodecCapability]
    ) -> String {
        let descriptors = codecs.map {
            WebRTCCodecPreferenceDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                parameters: $0.parameters
            )
        }
        return capabilitySummary(from: descriptors)
    }

    package nonisolated static func capabilitySummary(
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> String {
        let av1Descriptors = descriptors.filter {
            $0.name.caseInsensitiveCompare(WebRTCVideoCodec.av1.codecName) == .orderedSame
        }
        let otherCodecCount = descriptors.count - av1Descriptors.count
        return [
            "AV1=\(capabilityProbeSummary(from: av1Descriptors))",
            "unsupportedVideoCodecCount=\(otherCodecCount)",
        ].joined(separator: "; ")
    }

    private nonisolated static func capabilityProbeSummary(
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> String {
        guard !descriptors.isEmpty else { return "missing" }
        return descriptors.map { descriptor in
            let payloadType = descriptor.payloadType.map(String.init) ?? "none"
            let parameters = descriptor.parameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            return "\(descriptor.name)(pt=\(payloadType),fmtp=\(parameters.isEmpty ? "none" : parameters))"
        }
        .joined(separator: ",")
    }

    package nonisolated static func sdpVideoCodecSummary(from sdp: String) -> String {
        let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
        var currentVideoPayloadTypes: [String] = []
        var currentPayloadNames: [String: String] = [:]
        var isVideoMedia = false
        var summary: [String] = []
        var unexpectedCodecCount = 0

        func flushVideoMedia() {
            guard isVideoMedia else { return }
            for payloadType in currentVideoPayloadTypes {
                guard let name = currentPayloadNames[payloadType] else { continue }
                let normalizedName = name.lowercased()
                guard normalizedName == "av1" || normalizedName == "rtx" else {
                    unexpectedCodecCount += 1
                    continue
                }
                summary.append("\(payloadType):\(name)")
            }
        }

        for line in lines {
            if line.hasPrefix("m=") {
                flushVideoMedia()
                isVideoMedia = line.hasPrefix("m=video ")
                currentVideoPayloadTypes = []
                currentPayloadNames = [:]
                if isVideoMedia {
                    let parts = line.split(separator: " ").map(String.init)
                    if parts.count > 3 {
                        currentVideoPayloadTypes = Array(parts.dropFirst(3))
                    }
                }
                continue
            }

            guard isVideoMedia, line.hasPrefix("a=rtpmap:") else { continue }
            let mapping = line.dropFirst("a=rtpmap:".count)
            guard let separator = mapping.firstIndex(of: " ") else { continue }
            let payloadType = String(mapping[..<separator])
            let codecName = mapping[mapping.index(after: separator)...]
                .split(separator: "/", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            currentPayloadNames[payloadType] = codecName
        }
        flushVideoMedia()

        let text = summary.isEmpty ? "none" : summary.joined(separator: ",")
        return "\(text); unexpectedVideoCodecCount=\(unexpectedCodecCount)"
    }
}
#endif
