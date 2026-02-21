//
//  HttpHelper.swift
//  VoidDisplay
//
//

import Foundation
import UniformTypeIdentifiers

struct HTTPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let body: Data
}

struct HTTPRequestParser {
    private static let sectionSeparator = Data("\r\n\r\n".utf8)

    func parse(data: Data) -> HTTPRequest? {
        let split = splitHeaderAndBody(from: data)
        guard let headerSection = String(data: split.header, encoding: .utf8) else {
            return nil
        }
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first, !requestLine.isEmpty else {
            return nil
        }

        guard let (method, path, version) = parseRequestLine(requestLine) else {
            return nil
        }

        return HTTPRequest(
            method: method,
            path: path,
            version: version,
            headers: parseHeaders(headerLines.dropFirst()),
            body: split.body
        )
    }

    private func splitHeaderAndBody(from data: Data) -> (header: Data, body: Data) {
        guard let boundary = data.range(of: Self.sectionSeparator) else {
            // Allow header-only payloads when terminator is missing.
            return (data, Data())
        }
        let headerData = data[..<boundary.lowerBound]
        let bodyData = data[boundary.upperBound...]
        return (Data(headerData), Data(bodyData))
    }

    private func parseRequestLine(_ line: String) -> (method: String, path: String, version: String)? {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count == 3 else {
            return nil
        }
        return (parts[0], parts[1], parts[2])
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else {
                continue
            }
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return headers
    }
}

func parseHTTPRequest(from data: Data) -> (
    method: String,
    path: String,
    version: String,
    headers: [String: String],
    body: Data
)? {
    guard let request = HTTPRequestParser().parse(data: data) else {
        return nil
    }
    return (
        method: request.method,
        path: request.path,
        version: request.version,
        headers: request.headers,
        body: request.body
    )
}

extension NSImage {
    var jpegDataRepresentation: Data? {
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

    // Compatibility alias for existing callers.
    var jpgRepresentation: Data? {
        jpegDataRepresentation
    }
}
