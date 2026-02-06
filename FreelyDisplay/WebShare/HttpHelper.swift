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
    guard let requestString = String(data: data, encoding: .utf8) else {
        return nil
    }
    let parts = requestString.components(separatedBy: "\r\n\r\n")
    guard parts.count >= 1 else {
        return nil
    }
    let headerSection = parts[0]
    let bodyString = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
    let bodyData = bodyString.data(using: .utf8) ?? Data()
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
    
    return (method, path, version, headers, bodyData)
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
