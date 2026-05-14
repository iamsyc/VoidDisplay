import Foundation
import Testing

struct DiagnosticsUserFacingCopyTests {
    @Test func diagnosticsUserFacingCopyDoesNotExposeSurfaceTerminology() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbiddenFragments = [
            "DisplaySurface",
            "Display Surface",
            "Display Surfaces",
            "Surface Detail",
            "Surface Kind",
            "Surface Count",
            "Surface 数量",
            "显示表面"
        ]

        let localizableURL = repositoryRoot
            .appendingPathComponent("Apps/VoidDisplay/Resources/Localizable.xcstrings")
        let localizableContent = try String(contentsOf: localizableURL, encoding: .utf8)
        for fragment in forbiddenFragments {
            #expect(
                localizableContent.contains(fragment) == false,
                "Forbidden Localizable copy '\(fragment)' found in \(localizableURL.path)"
            )
        }

        let userFacingSourceFiles = try [
            repositoryRoot.appendingPathComponent("Sources/VoidDisplayApp/Navigation"),
            repositoryRoot.appendingPathComponent("Sources/VoidDisplaySupport/Views"),
            repositoryRoot.appendingPathComponent("Sources/VoidDisplayCapture/Views"),
            repositoryRoot.appendingPathComponent("Sources/VoidDisplaySharing/Views"),
            repositoryRoot.appendingPathComponent("Sources/VoidDisplayVirtualDisplay/Views")
        ].flatMap(swiftFiles(in:))

        for fileURL in userFacingSourceFiles {
            let literals = try swiftStringLiterals(in: fileURL)
            for fragment in forbiddenFragments {
                for literal in literals {
                    #expect(
                        literal.contains(fragment) == false,
                        "Forbidden user-facing copy '\(fragment)' found in \(fileURL.path): \(literal)"
                    )
                }
            }
        }
    }

    private func swiftFiles(in directoryURL: URL) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys)
        ) else {
            return []
        }

        return try enumerator.compactMap { element in
            guard let fileURL = element as? URL, fileURL.pathExtension == "swift" else {
                return nil
            }
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            return values.isRegularFile == true ? fileURL : nil
        }
    }

    private func swiftStringLiterals(in fileURL: URL) throws -> [String] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return expression.matches(in: content, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: content) else {
                return nil
            }
            return String(content[matchRange].dropFirst().dropLast())
        }
    }
}
