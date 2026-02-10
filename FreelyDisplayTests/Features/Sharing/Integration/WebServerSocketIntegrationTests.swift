import Foundation
import Testing
@testable import FreelyDisplay

@MainActor
private final class TargetStateStore {
    var stateByTarget: [ShareTarget: ShareTargetState]

    init(stateByTarget: [ShareTarget: ShareTargetState]) {
        self.stateByTarget = stateByTarget
    }

    func state(for target: ShareTarget) -> ShareTargetState {
        stateByTarget[target] ?? .unknown
    }
}

@MainActor
struct WebServerSocketIntegrationTests {

    @Test func rootRouteSupportsFragmentedSocketRequest() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .unknown },
            frameProvider: { _ in nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let responseData = try await Task.detached {
            try sendFragmentedRootRequestAndReadResponse(port: portValue)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("FreelyDisplay Share"))
    }

    @Test func streamRouteSendsMultipleFramesToSocketClient() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            frameProvider: { target in
                target == .main ? Data("frame-main".utf8) : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let responseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                path: "/stream",
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

    @Test func streamRouteRejectsNonGETMethodWith405() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            frameProvider: { target in
                target == .main ? Data("frame-main".utf8) : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let request = Data("POST /stream HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\nContent-Length: 0\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(
                port: portValue,
                request: request
            )
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("405 Method Not Allowed"))
        #expect(responseText.contains("Allow: GET"))
    }

    @Test func streamRouteSupportsFragmentedSocketRequestHeader() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            frameProvider: { target in
                target == .main ? Data("frame-main".utf8) : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let responseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                path: "/stream",
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
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .main ? .active : .unknown
            },
            frameProvider: { target in
                target == .main ? Data("frame-main".utf8) : nil
            }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let firstTask = Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                path: "/stream",
                boundary: streamBoundary,
                minimumFrameCount: 2
            )
        }
        let secondTask = Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                path: "/stream",
                boundary: streamBoundary,
                minimumFrameCount: 2
            )
        }

        let firstResponseData = try await firstTask.value
        let secondResponseData = try await secondTask.value

        let boundary = Data("--\(streamBoundary)\r\n".utf8)
        #expect(countOccurrences(of: boundary, in: firstResponseData) >= 2)
        #expect(countOccurrences(of: boundary, in: secondResponseData) >= 2)
    }

    @Test func streamRouteByIdUsesTargetSpecificFrameSource() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                switch target {
                case .id(1), .id(2):
                    return .active
                default:
                    return .unknown
                }
            },
            frameProvider: { target in
                switch target {
                case .id(1):
                    return Data("frame-for-1".utf8)
                case .id(2):
                    return Data("frame-for-2".utf8)
                default:
                    return nil
                }
            }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let firstResponseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                path: "/stream/1",
                boundary: streamBoundary,
                minimumFrameCount: 1
            )
        }.value
        let secondResponseData = try await Task.detached {
            try openStreamAndReadResponse(
                port: portValue,
                path: "/stream/2",
                boundary: streamBoundary,
                minimumFrameCount: 1
            )
        }.value

        let firstText = try #require(String(data: firstResponseData, encoding: .utf8))
        let secondText = try #require(String(data: secondResponseData, encoding: .utf8))
        #expect(firstText.contains("HTTP/1.1 200 OK"))
        #expect(secondText.contains("HTTP/1.1 200 OK"))
        #expect(firstText.contains("frame-for-1"))
        #expect(secondText.contains("frame-for-2"))
    }

    @Test func stoppingOneTargetDisconnectsOnlyThatTargetClients() async throws {
        let stateStore = TargetStateStore(
            stateByTarget: [
                .id(1): .active,
                .id(2): .active
            ]
        )
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                stateStore.state(for: target)
            },
            frameProvider: { target in
                switch target {
                case .id(1):
                    return Data("frame-live-1".utf8)
                case .id(2):
                    return Data("frame-live-2".utf8)
                default:
                    return nil
                }
            }
        )
        let server = setup.server
        let portValue = setup.port
        let streamBoundary = WebRequestHandler.streamBoundary
        defer {
            server.stopListener()
        }

        let firstFD = try openStreamSocket(port: portValue, path: "/stream/1")
        defer { close(firstFD) }
        let secondFD = try openStreamSocket(port: portValue, path: "/stream/2")
        defer { close(secondFD) }

        _ = try await Task.detached {
            try readUntilFrameBoundaries(
                from: firstFD,
                boundary: streamBoundary,
                minimumCount: 1,
                timeoutMilliseconds: 3000
            )
        }.value
        _ = try await Task.detached {
            try readUntilFrameBoundaries(
                from: secondFD,
                boundary: streamBoundary,
                minimumCount: 1,
                timeoutMilliseconds: 3000
            )
        }.value

        stateStore.stateByTarget[.id(1)] = .knownInactive

        _ = try await Task.detached {
            try readUntilSocketClosed(from: firstFD, timeoutMilliseconds: 4000)
        }.value
        let secondData = try await Task.detached {
            try readUntilFrameBoundaries(
                from: secondFD,
                boundary: streamBoundary,
                minimumCount: 1,
                timeoutMilliseconds: 4000
            )
        }.value

        let secondText = try #require(String(data: secondData, encoding: .utf8))
        #expect(secondText.contains("frame-live-2"))
    }

    @Test func streamRouteReturns503WhenTargetExistsButInactive() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { target in
                target == .id(5) ? .knownInactive : .unknown
            },
            frameProvider: { _ in nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let request = Data("GET /stream/5 HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("503 Service Unavailable"))
    }

    @Test func streamRouteReturns404WhenTargetIsUnknown() async throws {
        let setup = try await startServerOnRandomPort(
            targetStateProvider: { _ in .unknown },
            frameProvider: { _ in nil }
        )
        let server = setup.server
        let portValue = setup.port
        defer {
            server.stopListener()
        }

        let request = Data("GET /stream/99 HTTP/1.1\r\nHost: 127.0.0.1:\(portValue)\r\n\r\n".utf8)
        let responseData = try await Task.detached {
            try sendRequestAndReadUntilClose(port: portValue, request: request)
        }.value

        let responseText = try #require(String(data: responseData, encoding: .utf8))
        #expect(responseText.contains("404 Not Found"))
    }
}
