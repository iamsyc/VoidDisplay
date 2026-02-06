import Foundation

enum HTTPRequestAccumulatorResult {
    case waiting
    case complete(Data?)
    case invalidTooLarge
}

struct HTTPRequestAccumulator {
    private let headerTerminator: Data
    private let maxBytes: Int
    private var buffer: Data = Data()

    nonisolated init(
        headerTerminator: Data = Data("\r\n\r\n".utf8),
        maxBytes: Int = 32 * 1024
    ) {
        self.headerTerminator = headerTerminator
        self.maxBytes = maxBytes
    }

    nonisolated mutating func ingest(chunk: Data?, isComplete: Bool) -> HTTPRequestAccumulatorResult {
        if let chunk, !chunk.isEmpty {
            buffer.append(chunk)
        }

        if buffer.count > maxBytes {
            return .invalidTooLarge
        }

        if buffer.range(of: headerTerminator) != nil {
            return .complete(buffer)
        }

        if isComplete {
            return .complete(buffer.isEmpty ? nil : buffer)
        }

        return .waiting
    }
}
