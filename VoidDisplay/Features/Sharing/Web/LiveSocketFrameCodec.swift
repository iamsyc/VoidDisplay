import Foundation

nonisolated func makeLiveConfigJSON(_ configuration: LiveVideoConfiguration) -> String {
    if let decoderDescriptionBase64 = configuration.decoderDescriptionBase64 {
        #"{"type":"config","codec":"\#(configuration.codec)","width":\#(configuration.width),"height":\#(configuration.height),"timescale":\#(configuration.timescale),"description":"\#(decoderDescriptionBase64)"}"#
    } else {
        #"{"type":"config","codec":"\#(configuration.codec)","width":\#(configuration.width),"height":\#(configuration.height),"timescale":\#(configuration.timescale)}"#
    }
}

nonisolated func encodeLiveVideoPacket(packet: EncodedVideoPacket, configRefresh: Bool) -> Data {
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

nonisolated func encodeWebSocketTextFrame(_ text: String) -> Data {
    encodeWebSocketFrame(opcode: 0x1, payload: Data(text.utf8))
}

nonisolated func encodeWebSocketBinaryFrame(_ payload: Data) -> Data {
    let maxChunkSize = 65_535 // 64 KB limit to accommodate WebKit restrictions
    
    if payload.count <= maxChunkSize {
        return encodeWebSocketFrame(opcode: 0x2, fin: true, payload: payload)
    }

    var result = Data(capacity: payload.count + (payload.count / maxChunkSize + 1) * 4)
    var offset = 0
    var isFirst = true
    
    while offset < payload.count {
        let chunkEnd = min(offset + maxChunkSize, payload.count)
        let chunk = payload[offset..<chunkEnd]
        let isLast = chunkEnd >= payload.count
        
        let opcode: UInt8 = isFirst ? 0x2 : 0x0
        result.append(encodeWebSocketFrame(opcode: opcode, fin: isLast, payload: chunk))
        
        offset = chunkEnd
        isFirst = false
    }
    
    return result
}

nonisolated private func encodeWebSocketFrame(opcode: UInt8, fin: Bool = true, payload: Data) -> Data {
    var frame = Data()
    let firstByte: UInt8 = (fin ? 0x80 : 0x00) | opcode
    frame.append(firstByte)

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
