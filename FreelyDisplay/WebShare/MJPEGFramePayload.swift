import Foundation

func makeMJPEGFramePayload(frame: Data, boundary: String) -> Data {
    let frameBoundary = "--\(boundary)\r\n"
    let contentTypeHeader = "Content-Type: image/jpeg\r\n"
    let contentLengthHeader = "Content-Length: \(frame.count)\r\n\r\n"

    return Data(frameBoundary.utf8)
    + Data(contentTypeHeader.utf8)
    + Data(contentLengthHeader.utf8)
    + frame
    + Data("\r\n".utf8)
}
