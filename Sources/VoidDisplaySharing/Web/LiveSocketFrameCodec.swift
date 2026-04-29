import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated enum DecodedWebSocketFrame {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(Data)
}
package nonisolated enum WebSocketFrameDecodeError: Equatable {
    case unexpectedContinuation
    case invalidUTF8Text
    case fragmentedControlFrame
    case oversizedControlFramePayload
    case invalidMasking
    case unsupportedOpcode(UInt8)
    case framePayloadTooLarge(UInt64)
    case continuationFromUnsupportedOpcode(UInt8)
    case continuationPayloadTooLarge
    case unexpectedDataFrameDuringContinuation
}
package nonisolated struct WebSocketFrameDecoderOutput {
    package let frames: [DecodedWebSocketFrame]
    package let errors: [WebSocketFrameDecodeError]
}
package nonisolated final class WebSocketFrameDecoder {
    private var buffer = Data()
    private var continuationOpcode: UInt8?
    private var continuationPayload = Data()

    private let maxFramePayloadBytes: Int
    private let maxContinuationPayloadBytes: Int
    private let requiresMaskedFrames: Bool

    package init(
        maxFramePayloadBytes: Int = 256 * 1024,
        maxContinuationPayloadBytes: Int = 256 * 1024,
        requiresMaskedFrames: Bool = false
    ) {
        self.maxFramePayloadBytes = maxFramePayloadBytes
        self.maxContinuationPayloadBytes = maxContinuationPayloadBytes
        self.requiresMaskedFrames = requiresMaskedFrames
    }

    package var remainder: Data {
        buffer
    }

    package func ingest(_ chunk: Data?) -> WebSocketFrameDecoderOutput {
        if let chunk, !chunk.isEmpty {
            buffer.append(chunk)
        }

        var frames: [DecodedWebSocketFrame] = []
        var errors: [WebSocketFrameDecodeError] = []
        var offset = 0
        var shouldAbort = false

        while true {
            guard buffer.count >= (offset + 2) else { break }

            let first = buffer[offset]
            let second = buffer[offset + 1]
            let fin = (first & 0x80) != 0
            let opcode = first & 0x0F
            let masked = (second & 0x80) != 0
            var payloadLength = UInt64(second & 0x7F)
            var cursor = offset + 2

            if requiresMaskedFrames && !masked {
                errors.append(.invalidMasking)
                shouldAbort = true
                break
            }

            let isControlFrame = opcode >= 0x8
            if isControlFrame && !fin {
                errors.append(.fragmentedControlFrame)
                shouldAbort = true
                break
            }

            if payloadLength == 126 {
                guard buffer.count >= (cursor + 2) else { break }
                payloadLength = UInt64(UInt16(buffer[cursor]) << 8 | UInt16(buffer[cursor + 1]))
                cursor += 2
            } else if payloadLength == 127 {
                guard buffer.count >= (cursor + 8) else { break }
                var value: UInt64 = 0
                for byteOffset in 0..<8 {
                    value = (value << 8) | UInt64(buffer[cursor + byteOffset])
                }
                payloadLength = value
                cursor += 8
            }

            if isControlFrame && payloadLength > 125 {
                errors.append(.oversizedControlFramePayload)
                shouldAbort = true
                break
            }

            if payloadLength > UInt64(maxFramePayloadBytes) {
                errors.append(.framePayloadTooLarge(payloadLength))
                shouldAbort = true
                break
            }

            let maskStart = cursor
            if masked {
                guard buffer.count >= (cursor + 4) else { break }
                cursor += 4
            }

            guard payloadLength <= UInt64(Int.max),
                  buffer.count >= (cursor + Int(payloadLength)) else {
                break
            }

            var payload = Data(buffer[cursor..<(cursor + Int(payloadLength))])
            cursor += Int(payloadLength)
            offset = cursor

            if masked {
                let mask = buffer[maskStart..<(maskStart + 4)]
                var unmasked = Data(capacity: payload.count)
                for (index, byte) in payload.enumerated() {
                    let maskByte = mask[mask.index(mask.startIndex, offsetBy: index % 4)]
                    unmasked.append(byte ^ maskByte)
                }
                payload = unmasked
            }

            switch opcode {
            case 0x0:
                guard let continuationOpcode else {
                    errors.append(.unexpectedContinuation)
                    shouldAbort = true
                    break
                }
                continuationPayload.append(payload)
                if continuationPayload.count > maxContinuationPayloadBytes {
                    errors.append(.continuationPayloadTooLarge)
                    shouldAbort = true
                    break
                }
                if fin {
                    if continuationOpcode == 0x1 {
                        guard let text = String(data: continuationPayload, encoding: .utf8) else {
                            errors.append(.invalidUTF8Text)
                            shouldAbort = true
                            break
                        }
                        frames.append(.text(text))
                    } else if continuationOpcode == 0x2 {
                        frames.append(.binary(continuationPayload))
                    } else {
                        errors.append(.continuationFromUnsupportedOpcode(continuationOpcode))
                        shouldAbort = true
                        break
                    }
                    self.continuationOpcode = nil
                    continuationPayload = Data()
                }

            case 0x1:
                if continuationOpcode != nil {
                    errors.append(.unexpectedDataFrameDuringContinuation)
                    shouldAbort = true
                    break
                }
                if fin {
                    guard let text = String(data: payload, encoding: .utf8) else {
                        errors.append(.invalidUTF8Text)
                        shouldAbort = true
                        break
                    }
                    frames.append(.text(text))
                } else {
                    continuationOpcode = opcode
                    continuationPayload = payload
                }

            case 0x2:
                if continuationOpcode != nil {
                    errors.append(.unexpectedDataFrameDuringContinuation)
                    shouldAbort = true
                    break
                }
                if fin {
                    frames.append(.binary(payload))
                } else {
                    continuationOpcode = opcode
                    continuationPayload = payload
                }

            case 0x8:
                frames.append(.close(payload))

            case 0x9:
                frames.append(.ping(payload))

            case 0xA:
                frames.append(.pong(payload))

            default:
                errors.append(.unsupportedOpcode(opcode))
                shouldAbort = true
            }

            if shouldAbort {
                break
            }
        }

        if offset > 0 {
            buffer.removeSubrange(0..<offset)
        }

        if shouldAbort {
            buffer.removeAll(keepingCapacity: true)
            continuationOpcode = nil
            continuationPayload.removeAll(keepingCapacity: true)
        }

        return WebSocketFrameDecoderOutput(frames: frames, errors: errors)
    }
}

package nonisolated func encodeWebSocketTextFrame(_ text: String) -> Data {
    encodeWebSocketFrame(opcode: 0x1, payload: Data(text.utf8))
}

package nonisolated func encodeWebSocketBinaryFrame(_ payload: Data) -> Data {
    encodeWebSocketFrame(opcode: 0x2, payload: payload)
}

package nonisolated func encodeWebSocketPongFrame(_ payload: Data = Data()) -> Data {
    encodeWebSocketFrame(opcode: 0xA, payload: payload)
}

package nonisolated func encodeWebSocketCloseFrame(code: UInt16? = nil) -> Data {
    var payload = Data()
    if let code {
        var be = code.bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
    }
    return encodeWebSocketFrame(opcode: 0x8, payload: payload)
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
