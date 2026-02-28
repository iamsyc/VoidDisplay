import Foundation

func makeLiveVideoPacket(packet: EncodedVideoPacket, configRefresh: Bool) -> Data {
    var data = Data(capacity: 18 + packet.payload.count)
    data.append(1)

    var flags: UInt8 = packet.isKeyframe ? 0x1 : 0x0
    if configRefresh {
        flags |= 0x2
    }
    data.append(flags)

    var pts = packet.ptsUs.bigEndian
    withUnsafeBytes(of: &pts) { data.append(contentsOf: $0) }

    var width = UInt32(packet.width).bigEndian
    withUnsafeBytes(of: &width) { data.append(contentsOf: $0) }

    var height = UInt32(packet.height).bigEndian
    withUnsafeBytes(of: &height) { data.append(contentsOf: $0) }

    data.append(packet.payload)
    return data
}

func makeWebSocketTextFrame(_ text: String) -> Data {
    makeWebSocketFrame(opcode: 0x1, payload: Data(text.utf8))
}

func makeWebSocketBinaryFrame(_ payload: Data) -> Data {
    makeWebSocketFrame(opcode: 0x2, payload: payload)
}

func makeWebSocketPongFrame(_ payload: Data) -> Data {
    makeWebSocketFrame(opcode: 0xA, payload: payload)
}

func makeWebSocketCloseFrame(_ payload: Data = Data()) -> Data {
    makeWebSocketFrame(opcode: 0x8, payload: payload)
}

private func makeWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
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
