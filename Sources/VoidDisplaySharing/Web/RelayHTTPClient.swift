import Foundation

package protocol RelayHTTPClienting: Sendable {
    nonisolated func publisherOffer(roomID: String, sdp: String) async throws -> RelayPublisherOfferResponse
    nonisolated func publisherCandidate(
        roomID: String,
        publisherID: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws
    nonisolated func viewerOffer(roomID: String, clientID: String, sdp: String) async throws -> RelayViewerOfferResponse
    nonisolated func viewerCandidate(
        roomID: String,
        clientID: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws
    nonisolated func removeViewer(roomID: String, clientID: String) async
    nonisolated func stopPublisher(roomID: String, publisherID: String) async
}

package struct RelayPublisherOfferResponse: Sendable, Equatable {
    package let sdp: String
    package let publisherID: String

    package init(sdp: String, publisherID: String) {
        self.sdp = sdp
        self.publisherID = publisherID
    }
}

package struct RelayViewerOfferResponse: Sendable, Equatable {
    package let sdp: String
    package let codec: WebRTCVideoCodec

    package init(sdp: String, codec: WebRTCVideoCodec) {
        self.sdp = sdp
        self.codec = codec
    }
}

package struct RelayReadyEvent: Decodable, Sendable {
    package let type: String
    package let loopback: String
}

package final class RelayHTTPClient: RelayHTTPClienting, @unchecked Sendable {
    private struct OfferRequest: Encodable {
        let type = "offer"
        let sdp: String
    }

    private struct CandidateRequest: Encodable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: UInt16?
    }

    private struct SignalResponse: Decodable {
        let type: String
        let sdp: String?
        let codec: String?
        let reason: String?
    }

    private struct ErrorResponse: Decodable {
        let type: String?
        let reason: String?
    }

    private struct PublisherOfferResponse: Decodable {
        let type: String
        let sdp: String?
        let publisherID: String?
        let reason: String?
    }

    private let baseURL: URL
    private let controlToken: String
    private let session: URLSession

    package init(baseURL: URL, controlToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.controlToken = controlToken
        self.session = session
    }

    package nonisolated func publisherOffer(roomID: String, sdp: String) async throws -> RelayPublisherOfferResponse {
        let response: PublisherOfferResponse = try await sendJSON(
            method: "POST",
            path: ["room", roomID, "publisher"],
            payload: OfferRequest(sdp: sdp)
        )
        guard response.type == "answer",
              let answerSDP = response.sdp,
              let publisherID = response.publisherID else {
            throw RelayHTTPError.unexpectedResponse(response.reason ?? response.type)
        }
        return RelayPublisherOfferResponse(sdp: answerSDP, publisherID: publisherID)
    }

    package nonisolated func publisherCandidate(
        roomID: String,
        publisherID: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws {
        try await postCandidate(
            path: ["room", roomID, "publisher", publisherID, "candidate"],
            candidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex
        )
    }

    package nonisolated func viewerOffer(roomID: String, clientID: String, sdp: String) async throws -> RelayViewerOfferResponse {
        try await postOffer(path: ["room", roomID, "viewer", clientID], sdp: sdp)
    }

    package nonisolated func viewerCandidate(
        roomID: String,
        clientID: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws {
        try await postCandidate(
            path: ["room", roomID, "viewer", clientID, "candidate"],
            candidate: candidate,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex
        )
    }

    package nonisolated func removeViewer(roomID: String, clientID: String) async {
        try? await sendEmpty(method: "DELETE", path: ["room", roomID, "viewer", clientID])
    }

    package nonisolated func stopPublisher(roomID: String, publisherID: String) async {
        try? await sendEmpty(method: "DELETE", path: ["room", roomID, "publisher", publisherID])
    }

    private nonisolated func postOffer(path: [String], sdp: String) async throws -> RelayViewerOfferResponse {
        let response: SignalResponse = try await sendJSON(
            method: "POST",
            path: path,
            payload: OfferRequest(sdp: sdp)
        )
        guard response.type == "answer", let answerSDP = response.sdp else {
            throw RelayHTTPError.unexpectedResponse(response.reason ?? response.type)
        }
        guard let rawCodec = response.codec,
              let codec = WebRTCVideoCodec(rawValue: rawCodec) else {
            throw RelayHTTPError.unexpectedResponse(response.codec ?? "missing_codec")
        }
        return RelayViewerOfferResponse(sdp: answerSDP, codec: codec)
    }

    private nonisolated func postCandidate(
        path: [String],
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws {
        let lineIndex: UInt16?
        if sdpMLineIndex >= 0, sdpMLineIndex <= Int32(UInt16.max) {
            lineIndex = UInt16(sdpMLineIndex)
        } else {
            lineIndex = nil
        }
        try await sendEmptyJSON(
            method: "POST",
            path: path,
            payload: CandidateRequest(
                candidate: candidate,
                sdpMid: sdpMid,
                sdpMLineIndex: lineIndex
            )
        )
    }

    private nonisolated func sendJSON<Response: Decodable, Payload: Encodable>(
        method: String,
        path: [String],
        payload: Payload
    ) async throws -> Response {
        var request = makeRequest(method: method, path: path)
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private nonisolated func sendEmptyJSON<Payload: Encodable>(
        method: String,
        path: [String],
        payload: Payload
    ) async throws {
        var request = makeRequest(method: method, path: path)
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    private nonisolated func sendEmpty(method: String, path: [String]) async throws {
        let request = makeRequest(method: method, path: path)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    private nonisolated func makeRequest(method: String, path: [String]) -> URLRequest {
        var url = baseURL
        for component in path {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(controlToken, forHTTPHeaderField: "X-Control-Token")
        request.timeoutInterval = 5
        return request
    }

    private nonisolated static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayHTTPError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data).reason)
                ?? String(data: data, encoding: .utf8)
                ?? "status_\(httpResponse.statusCode)"
            throw RelayHTTPError.httpStatus(httpResponse.statusCode, reason)
        }
    }
}

package enum RelayHTTPError: Error, LocalizedError, Equatable {
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case unexpectedResponse(String)

    package var relayReason: String? {
        switch self {
        case .httpStatus(_, let reason), .unexpectedResponse(let reason):
            reason
        case .invalidHTTPResponse:
            nil
        }
    }

    package var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "Invalid relay HTTP response."
        case .httpStatus(let status, let reason):
            "Relay HTTP request failed with status \(status): \(reason)"
        case .unexpectedResponse(let reason):
            "Unexpected relay response: \(reason)"
        }
    }
}
