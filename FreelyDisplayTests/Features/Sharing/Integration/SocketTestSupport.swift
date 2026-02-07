import Foundation
import Network
import Darwin
@testable import FreelyDisplay

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

func countOccurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
    var count = 0
    var searchRangeStart = haystack.startIndex

    while searchRangeStart < haystack.endIndex,
          let range = haystack.range(of: needle, in: searchRangeStart..<haystack.endIndex) {
        count += 1
        searchRangeStart = range.upperBound
    }

    return count
}

func configureReceiveTimeout(fd: Int32, milliseconds: Int) {
    var timeout = timeval(
        tv_sec: __darwin_time_t(milliseconds / 1000),
        tv_usec: __darwin_suseconds_t((milliseconds % 1000) * 1000)
    )
    _ = withUnsafePointer(to: &timeout) { ptr in
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            ptr,
            socklen_t(MemoryLayout<timeval>.size)
        )
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

func readUntilFrameBoundaries(
    from fd: Int32,
    boundary: String,
    minimumCount: Int,
    timeoutMilliseconds: Int
) throws -> Data {
    let boundaryData = Data("--\(boundary)\r\n".utf8)
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000.0)

    while Date() < deadline {
        let readBytes = recv(fd, &buffer, buffer.count, 0)
        if readBytes > 0 {
            response.append(buffer, count: readBytes)
            if countOccurrences(of: boundaryData, in: response) >= minimumCount {
                return response
            }
            continue
        }
        if readBytes == 0 {
            break
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
            continue
        }
        throw SocketIntegrationError.receiveFailed
    }

    throw SocketIntegrationError.receiveTimeout
}

func readUntilSocketClosed(from fd: Int32, timeoutMilliseconds: Int) throws -> Data {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000.0)

    while Date() < deadline {
        let readBytes = recv(fd, &buffer, buffer.count, 0)
        if readBytes > 0 {
            response.append(buffer, count: readBytes)
            continue
        }
        if readBytes == 0 {
            return response
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            continue
        }
        throw SocketIntegrationError.receiveFailed
    }

    throw SocketIntegrationError.receiveTimeout
}

func sendFragmentedRootRequestAndReadResponse(port: UInt16) throws -> Data {
    let fd = try connectLoopbackSocket(port: port)
    defer { close(fd) }

    let fragment1 = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1".utf8)
    let fragment2 = Data(":\(port)\r\n\r\n".utf8)
    try sendAll(fd, data: fragment1)
    usleep(50_000)
    try sendAll(fd, data: fragment2)
    _ = shutdown(fd, SHUT_WR)

    return try readAll(from: fd)
}

func openStreamAndReadResponse(
    port: UInt16,
    boundary: String,
    minimumFrameCount: Int,
    fragmentedHeader: Bool = false
) throws -> Data {
    let fd = try openStreamSocket(port: port, fragmentedHeader: fragmentedHeader)
    defer { close(fd) }
    return try readUntilFrameBoundaries(
        from: fd,
        boundary: boundary,
        minimumCount: minimumFrameCount,
        timeoutMilliseconds: 3000
    )
}

func openStreamSocket(
    port: UInt16,
    fragmentedHeader: Bool = false
) throws -> Int32 {
    let fd = try connectLoopbackSocket(port: port)
    configureReceiveTimeout(fd: fd, milliseconds: 300)

    if fragmentedHeader {
        let fragment1 = Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1".utf8)
        let fragment2 = Data(":\(port)\r\n\r\n".utf8)
        try sendAll(fd, data: fragment1)
        usleep(50_000)
        try sendAll(fd, data: fragment2)
    } else {
        let request = Data("GET /stream HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
        try sendAll(fd, data: request)
    }
    return fd
}

@MainActor
func startServerOnRandomPort(
    isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
    frameProvider: @escaping @MainActor @Sendable () -> Data?
) throws -> (server: WebServer, port: UInt16) {
    for _ in 0..<80 {
        let candidate = UInt16.random(in: 20_000...60_000)
        guard let endpointPort = NWEndpoint.Port(rawValue: candidate) else {
            continue
        }
        do {
            let server = try WebServer(
                using: endpointPort,
                isSharingProvider: isSharingProvider,
                frameProvider: frameProvider
            )
            server.startListener()
            if let probeSocket = try? connectLoopbackSocket(port: candidate) {
                close(probeSocket)
                return (server, candidate)
            }
            server.stopListener()
            continue
        } catch let error as NWError {
            if case .posix(let code) = error, code == .EADDRINUSE {
                continue
            }
            throw error
        } catch {
            throw error
        }
    }
    throw SocketIntegrationError.bindFailed
}
