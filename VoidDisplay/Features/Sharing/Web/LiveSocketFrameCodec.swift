import Foundation

enum DecodedWebSocketFrame {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(Data)
}

nonisolated func encodeWebSocketTextFrame(_ text: String) -> Data {
    encodeWebSocketFrame(opcode: 0x1, payload: Data(text.utf8))
}

nonisolated func encodeWebSocketBinaryFrame(_ payload: Data) -> Data {
    encodeWebSocketFrame(opcode: 0x2, payload: payload)
}

nonisolated func encodeWebSocketPongFrame(_ payload: Data = Data()) -> Data {
    encodeWebSocketFrame(opcode: 0xA, payload: payload)
}

nonisolated func encodeWebSocketCloseFrame(code: UInt16? = nil) -> Data {
    var payload = Data()
    if let code {
        var be = code.bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
    }
    return encodeWebSocketFrame(opcode: 0x8, payload: payload)
}

nonisolated func decodeWebSocketFrames(from input: Data) -> (frames: [DecodedWebSocketFrame], remainder: Data) {
    var frames: [DecodedWebSocketFrame] = []
    var offset = 0

    while true {
        guard input.count >= (offset + 2) else { break }

        let first = input[offset]
        let second = input[offset + 1]
        let fin = (first & 0x80) != 0
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var payloadLength = UInt64(second & 0x7F)
        var cursor = offset + 2

        if payloadLength == 126 {
            guard input.count >= (cursor + 2) else { break }
            payloadLength = UInt64(UInt16(input[cursor]) << 8 | UInt16(input[cursor + 1]))
            cursor += 2
        } else if payloadLength == 127 {
            guard input.count >= (cursor + 8) else { break }
            var value: UInt64 = 0
            for byteOffset in 0..<8 {
                value = (value << 8) | UInt64(input[cursor + byteOffset])
            }
            payloadLength = value
            cursor += 8
        }

        let maskStart = cursor
        if masked {
            guard input.count >= (cursor + 4) else { break }
            cursor += 4
        }

        guard payloadLength <= UInt64(Int.max),
              input.count >= (cursor + Int(payloadLength)) else { break }

        var payload = Data(input[cursor..<(cursor + Int(payloadLength))])
        cursor += Int(payloadLength)
        offset = cursor

        if masked {
            let mask = input[maskStart..<(maskStart + 4)]
            var unmasked = Data(capacity: payload.count)
            for (index, byte) in payload.enumerated() {
                let maskByte = mask[mask.index(mask.startIndex, offsetBy: index % 4)]
                unmasked.append(byte ^ maskByte)
            }
            payload = unmasked
        }

        guard fin else { continue } // The server doesn't support fragmented inbound signaling frames.

        switch opcode {
        case 0x1:
            if let text = String(data: payload, encoding: .utf8) {
                frames.append(.text(text))
            }
        case 0x2:
            frames.append(.binary(payload))
        case 0x8:
            frames.append(.close(payload))
        case 0x9:
            frames.append(.ping(payload))
        case 0xA:
            frames.append(.pong(payload))
        default:
            continue
        }
    }

    let remainder = offset < input.count ? Data(input[offset...]) : Data()
    return (frames, remainder)
}

nonisolated private func encodeWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
    var frame = Data()
    frame.append(0x80 | opcode)

    let length = payload.count
    if length <= 125 {
        frame.append(UInt8(length))
    } else if length <= 65_535 {
        frame.append(126)
        var value = UInt16(length).bigEndian
        withUnsafeBytes(of: &value) { frame.append(contentsOf: $0) }
    } else {
        frame.append(127)
        var value = UInt64(length).bigEndian
        withUnsafeBytes(of: &value) { frame.append(contentsOf: $0) }
    }

    frame.append(payload)
    return frame
}
