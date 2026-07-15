@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Darwin
import Foundation
import Network

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
        if errno == EWOULDBLOCK || errno == EAGAIN {
            if !response.isEmpty {
                return response
            }
            throw SocketIntegrationError.receiveTimeout
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

func connectLoopbackSocket(port: UInt16) async throws -> Int32 {
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
            await Task.yield()
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
    timeoutMilliseconds: Int = 5000
) async throws -> Data {
    let fd = try await connectLoopbackSocket(port: port)
    defer { close(fd) }
    configureReceiveTimeout(fd: fd, milliseconds: timeoutMilliseconds)
    try sendAll(fd, data: request)
    _ = shutdown(fd, SHUT_WR)
    return try readAll(from: fd)
}

func readUntilHeaderTerminator(
    from fd: Int32,
    timeoutMilliseconds: Int = 500,
    deadlineSeconds: TimeInterval = 15
) throws -> Data {
    configureReceiveTimeout(fd: fd, milliseconds: timeoutMilliseconds)
    let deadline = Date().addingTimeInterval(deadlineSeconds)
    let terminator = Data("\r\n\r\n".utf8)
    var buffer = [UInt8](repeating: 0, count: 4096)
    var collected = Data()
    while true {
        let bytes = recv(fd, &buffer, buffer.count, 0)
        if bytes > 0 {
            collected.append(buffer, count: bytes)
            if collected.range(of: terminator) != nil {
                return collected
            }
            continue
        }
        if bytes == 0 {
            return collected
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            if Date() >= deadline {
                if !collected.isEmpty {
                    return collected
                }
                throw SocketIntegrationError.receiveTimeout
            }
            continue
        }
        throw SocketIntegrationError.receiveFailed
    }
}

func waitForCloseOrEOF(
    from fd: Int32,
    timeoutMilliseconds: Int = 500,
    deadlineSeconds: TimeInterval = 10
) throws -> Bool {
    configureReceiveTimeout(fd: fd, milliseconds: timeoutMilliseconds)
    let deadline = Date().addingTimeInterval(deadlineSeconds)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let decoder = WebSocketFrameDecoder(
        maxFramePayloadBytes: Int.max,
        maxContinuationPayloadBytes: Int.max
    )
    while true {
        let bytes = recv(fd, &buffer, buffer.count, 0)
        if bytes > 0 {
            let output = decoder.ingest(Data(buffer.prefix(bytes)))
            for frame in output.frames {
                if case .close = frame {
                    return true
                }
            }
            continue
        }
        if bytes == 0 {
            return true
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            if Date() >= deadline {
                return false
            }
            continue
        }
        if errno == ECONNRESET || errno == ENOTCONN {
            return true
        }
        throw SocketIntegrationError.receiveFailed
    }
}

func makeMaskedTextFrame(_ text: String) -> Data {
    let payload = Data(text.utf8)
    let mask: [UInt8] = [0x10, 0x32, 0x54, 0x76]
    var frame = Data([0x81])
    if payload.count <= 125 {
        frame.append(0x80 | UInt8(payload.count))
    } else if payload.count <= Int(UInt16.max) {
        frame.append(0x80 | 126)
        var length = UInt16(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    } else {
        frame.append(0x80 | 127)
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    }
    frame.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() {
        frame.append(byte ^ mask[index % 4])
    }
    return frame
}

func websocketUpgradeRequest(path: String, port: UInt16) -> Data {
    let request =
        "GET \(path) HTTP/1.1\r\n" +
        "Host: 127.0.0.1:\(port)\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
        "\r\n"
    return Data(request.utf8)
}

@MainActor
func startServerOnRandomPort(
    targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
    concreteTargetResolver: @escaping @MainActor @Sendable (ShareTarget) -> ShareTarget? = { target in
        guard case .id(let id) = target else { return nil }
        return .id(id)
    },
    sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> (any SignalSessionHub)?,
    sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void = { _ in }
) async throws -> (server: WebServer, port: UInt16) {
    for candidate in TestPortAllocator.randomPortCandidates(count: 60) {
        guard let endpointPort = NWEndpoint.Port(rawValue: candidate) else {
            continue
        }
        do {
            let server = try WebServer(
                using: endpointPort,
                targetStateProvider: targetStateProvider,
                concreteTargetResolver: concreteTargetResolver,
                sessionHubProvider: sessionHubProvider,
                sharingEventSink: sharingEventSink
            )
            let result = await server.startListener(timeout: 1.0)
            switch result {
            case .ready(let boundPort):
                return (server, boundPort)
            case .timedOut:
                server.stopListener()
            case .failed:
                server.stopListener()
            }
        } catch {
            await Task.yield()
        }
    }

    throw SocketIntegrationError.bindFailed
}
