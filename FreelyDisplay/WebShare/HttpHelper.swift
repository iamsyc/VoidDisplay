//
//  HttpHelper.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/14.
//

import Foundation
import UniformTypeIdentifiers

func parseHTTPRequest(from data: Data) -> (
    method: String,
    path: String,
    version: String,
    headers: [String: String],
    body: Data
)? {
    let separator = Data("\r\n\r\n".utf8)
    let headerAndBody: (header: Data, body: Data)
    if let boundary = data.range(of: separator) {
        let headerData = data[..<boundary.lowerBound]
        let bodyData = data[boundary.upperBound...]
        headerAndBody = (Data(headerData), Data(bodyData))
    } else {
        // Allow header-only payloads when terminator is missing.
        headerAndBody = (data, Data())
    }

    guard let headerSection = String(data: headerAndBody.header, encoding: .utf8) else {
        return nil
    }
    let headerLines = headerSection.components(separatedBy: "\r\n")
    guard let firstLine = headerLines.first, !firstLine.isEmpty else {
        return nil
    }
    let requestLineParts = firstLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    guard requestLineParts.count == 3 else {
        return nil
    }
    let method = requestLineParts[0]
    let path = requestLineParts[1]
    let version = requestLineParts[2]
    var headers: [String: String] = [:]
    for line in headerLines.dropFirst() where !line.isEmpty {
        guard let colonIndex = line.firstIndex(of: ":") else {
            continue
        }
        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let valueStart = line.index(after: colonIndex)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        headers[key.lowercased()] = value
    }
    
    return (method, path, version, headers, headerAndBody.body)
}

extension NSImage {
    var jpgRepresentation: Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? mutableData as Data : nil
    }
}
