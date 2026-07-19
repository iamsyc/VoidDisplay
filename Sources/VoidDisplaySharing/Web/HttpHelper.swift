import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
//
//  HttpHelper.swift
//  VoidDisplay
//
//

import Foundation
package struct HTTPRequest {
    package let method: String
    package let path: String
    package let headers: [String: String]
}
package struct HTTPRequestParser {
    private static let sectionSeparator = Data("\r\n\r\n".utf8)

    package func parse(data: Data) -> HTTPRequest? {
        guard let boundary = data.range(of: Self.sectionSeparator) else { return nil }
        let headerData = data[..<boundary.lowerBound]
        guard let headerSection = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first, !requestLine.isEmpty else {
            return nil
        }

        guard let (method, path) = parseRequestLine(requestLine),
              let headers = parseHeaders(headerLines.dropFirst()) else {
            return nil
        }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers
        )
    }

    private func parseRequestLine(_ line: String) -> (method: String, path: String)? {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count == 3, parts[2] == "HTTP/1.1" else {
            return nil
        }
        return (parts[0], parts[1])
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { return nil }
            let key = String(line[..<colonIndex]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy(Self.isHeaderNameByte) else { return nil }
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return headers
    }

    private static func isHeaderNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122,
             33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            true
        default:
            false
        }
    }
}

package func parseHTTPRequest(from data: Data) -> (
    method: String,
    path: String,
    headers: [String: String]
)? {
    guard let request = HTTPRequestParser().parse(data: data) else {
        return nil
    }
    return (
        method: request.method,
        path: request.path,
        headers: request.headers
    )
}
