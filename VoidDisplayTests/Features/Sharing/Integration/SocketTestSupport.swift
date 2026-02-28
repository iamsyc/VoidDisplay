import Darwin
import Foundation
import Network
@testable import VoidDisplay

enum SocketIntegrationError: Error {
    case connectionRefused
    case socketCreationFailed
    case bindFailed
    case sendFailed
    case receiveFailed
    case receiveTimeout
}

func sendAll(_ fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var bytesSent = 0
        while bytesSent < rawBuffer.count {
            let pointer = baseAddress.advanced(by: bytesSent)
            let sent = Darwin.send(fd, pointer, rawBuffer.count - bytesSent, 0)
            guard sent >= 0 else { throw SocketIntegrationError.sendFailed }
            bytesSent += sent
        }
    }
}

func readAll(from fd: Int32) throws -> Data {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let readBytes = recv(fd, &buffer, buffer.count, 0)
        if readBytes > 0 {
            response.append(buffer, count: readBytes)
            continue
        }
        if readBytes == 0 {
            return response
        }
        throw SocketIntegrationError.receiveFailed
    }
}

func configureReceiveTimeout(fd: Int32, milliseconds: Int) {
    var timeout = timeval(
        tv_sec: __darwin_time_t(milliseconds / 1000),
        tv_usec: __darwin_suseconds_t((milliseconds % 1000) * 1000)
    )
    _ = withUnsafePointer(to: &timeout) { ptr in
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
    }
}

func connectLoopbackSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketIntegrationError.socketCreationFailed }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    var connected = false
    for _ in 0..<20 {
        let connectResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if connectResult == 0 {
            connected = true
            break
        }

        if errno == ECONNREFUSED || errno == EHOSTUNREACH || errno == ENETDOWN || errno == ENETUNREACH {
            usleep(50_000)
            continue
        }
        close(fd)
        throw SocketIntegrationError.connectionRefused
    }
    guard connected else {
        close(fd)
        throw SocketIntegrationError.connectionRefused
    }
    return fd
}

func sendRequestAndReadUntilClose(
    port: UInt16,
    request: Data,
    timeoutMilliseconds: Int = 3000
) throws -> Data {
    let fd = try connectLoopbackSocket(port: port)
    defer { close(fd) }
    configureReceiveTimeout(fd: fd, milliseconds: 300)
    try sendAll(fd, data: request)
    _ = shutdown(fd, SHUT_WR)
    return try readAll(from: fd)
}

func sendRequestAndReadPartialResponse(
    port: UInt16,
    request: Data,
    timeoutMilliseconds: Int = 3000
) throws -> Data {
    let fd = try connectLoopbackSocket(port: port)
    defer { close(fd) }
    configureReceiveTimeout(fd: fd, milliseconds: timeoutMilliseconds)
    try sendAll(fd, data: request)
    _ = shutdown(fd, SHUT_WR)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let terminator = Data("\r\n\r\n".utf8)

    while true {
        let readBytes = recv(fd, &buffer, buffer.count, 0)
        if readBytes > 0 {
            response.append(buffer, count: readBytes)
            if response.range(of: terminator) != nil {
                return response
            }
            continue
        }

        if readBytes == 0, !response.isEmpty {
            return response
        }

        if errno == EWOULDBLOCK || errno == EAGAIN {
            if !response.isEmpty {
                return response
            }
            throw SocketIntegrationError.receiveTimeout
        }

        if response.isEmpty {
            throw SocketIntegrationError.receiveTimeout
        } else {
            return response
        }
    }
}

func websocketUpgradeRequest(path: String, port: UInt16) -> Data {
    Data(
        """
        GET \(path) HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r
        """.utf8
    )
}

@MainActor
private final class StaticLiveHubStore {
    let hub = LiveSocketHub()
}

@MainActor
func startServerOnRandomPort(
    targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
    liveHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> LiveSocketHub?
) async throws -> (server: WebServer, port: UInt16) {
    guard let endpointPort = NWEndpoint.Port(rawValue: 0) else {
        throw SocketIntegrationError.bindFailed
    }

    for _ in 0..<60 {
        do {
            let server = try WebServer(
                using: endpointPort,
                targetStateProvider: targetStateProvider,
                liveHubProvider: liveHubProvider
            )
            let result = await server.startListener(timeout: 1.0)
            switch result {
            case .ready(let boundPort):
                return (server, boundPort)
            case .timedOut:
                server.stopListener()
            case .failed(let error):
                server.stopListener()
                throw error
            }
        } catch {
            usleep(50_000)
        }
    }

    throw SocketIntegrationError.bindFailed
}
