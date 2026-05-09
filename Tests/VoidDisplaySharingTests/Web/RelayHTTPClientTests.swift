@testable import VoidDisplaySharing
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct RelayHTTPClientTests {
    @Test func publisherOfferDecodesPublisherID() async throws {
        let transport = RelayHTTPClientMockTransport(
            responses: [
                MockHTTPResponse(
                    statusCode: 200,
                    body: #"{"type":"answer","sdp":"publisher-answer","publisherID":"publisher-7"}"#
                )
            ]
        )
        let client = RelayHTTPClient(
            baseURL: URL(string: "http://relay.test")!,
            controlToken: "token",
            session: transport.session
        )

        let response = try await client.publisherOffer(roomID: "2", sdp: "publisher-offer")

        #expect(response == RelayPublisherOfferResponse(sdp: "publisher-answer", publisherID: "publisher-7"))
        let request = try #require(transport.requests().first)
        #expect(request.method == "POST")
        #expect(request.path == "/room/2/publisher")
        #expect(request.controlToken == "token")
        #expect(request.body.contains(#""sdp":"publisher-offer""#))
    }

    @Test func publisherCandidateAndStopUsePublisherIDPath() async throws {
        let transport = RelayHTTPClientMockTransport(
            responses: [
                MockHTTPResponse(statusCode: 204, body: ""),
                MockHTTPResponse(statusCode: 204, body: ""),
            ]
        )
        let client = RelayHTTPClient(
            baseURL: URL(string: "http://relay.test")!,
            controlToken: "token",
            session: transport.session
        )

        try await client.publisherCandidate(
            roomID: "2",
            publisherID: "publisher-7",
            candidate: "candidate:1",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        await client.stopPublisher(roomID: "2", publisherID: "publisher-7")

        let requests = transport.requests()
        #expect(requests.map(\.path) == [
            "/room/2/publisher/publisher-7/candidate",
            "/room/2/publisher/publisher-7",
        ])
        #expect(requests.map(\.method) == ["POST", "DELETE"])
        #expect(requests.first?.body.contains(#""candidate":"candidate:1""#) == true)
    }

    @Test func viewerOfferExposesRelayErrorReason() async throws {
        let transport = RelayHTTPClientMockTransport(
            responses: [
                MockHTTPResponse(
                    statusCode: 400,
                    body: #"{"type":"error","reason":"publisher_codec_pending"}"#
                )
            ]
        )
        let client = RelayHTTPClient(
            baseURL: URL(string: "http://relay.test")!,
            controlToken: "token",
            session: transport.session
        )

        do {
            _ = try await client.viewerOffer(roomID: "2", clientID: "viewer-1", sdp: "viewer-offer")
            Issue.record("viewerOffer succeeded for relay error response")
        } catch let error as RelayHTTPError {
            #expect(error == .httpStatus(400, "publisher_codec_pending"))
            #expect(error.relayReason == "publisher_codec_pending")
        }
    }

    @Test func viewerOfferDecodesSelectedCodec() async throws {
        let transport = RelayHTTPClientMockTransport(
            responses: [
                MockHTTPResponse(
                    statusCode: 200,
                    body: #"{"type":"answer","sdp":"viewer-answer","codec":"av1"}"#
                )
            ]
        )
        let client = RelayHTTPClient(
            baseURL: URL(string: "http://relay.test")!,
            controlToken: "token",
            session: transport.session
        )

        let response = try await client.viewerOffer(roomID: "2", clientID: "viewer-1", sdp: "viewer-offer")

        #expect(response == RelayViewerOfferResponse(sdp: "viewer-answer", codec: .av1))
        let request = try #require(transport.requests().first)
        #expect(request.path == "/room/2/viewer/viewer-1")
        #expect(request.body.contains(#""sdp":"viewer-offer""#))
    }
}

private struct MockHTTPResponse: Sendable {
    let statusCode: Int
    let body: String
}

private struct RecordedHTTPRequest: Sendable, Equatable {
    let method: String
    let path: String
    let controlToken: String?
    let body: String
}

private final class RelayHTTPClientMockTransport: @unchecked Sendable {
    private struct State {
        var responses: [MockHTTPResponse]
        var requests: [RecordedHTTPRequest] = []
    }

    private let state: Mutex<State>
    let session: URLSession

    init(responses: [MockHTTPResponse]) {
        state = Mutex(State(responses: responses))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayHTTPClientURLProtocol.self]
        session = URLSession(configuration: configuration)
        RelayHTTPClientURLProtocol.handler = { request in
            self.state.withLock { state in
                let body: String
                if let httpBody = request.httpBody {
                    body = String(data: httpBody, encoding: .utf8) ?? ""
                } else if let bodyStream = request.httpBodyStream {
                    body = Self.readBodyStream(bodyStream)
                } else {
                    body = ""
                }
                state.requests.append(
                    RecordedHTTPRequest(
                        method: request.httpMethod ?? "",
                        path: request.url?.path ?? "",
                        controlToken: request.value(forHTTPHeaderField: "X-Control-Token"),
                        body: body
                    )
                )
                return state.responses.removeFirst()
            }
        }
    }

    func requests() -> [RecordedHTTPRequest] {
        state.withLock { $0.requests }
    }

    private static func readBodyStream(_ stream: InputStream) -> String {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class RelayHTTPClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> MockHTTPResponse)?

    override nonisolated class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override nonisolated func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: RelayHTTPClientMockError.missingHandler)
            return
        }
        let result = handler(request)
        let data = Data(result.body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override nonisolated func stopLoading() {}
}

private enum RelayHTTPClientMockError: Error {
    case missingHandler
}
