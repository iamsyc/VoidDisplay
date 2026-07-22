import Foundation
import Testing

struct DiagnosticsUserFacingCopyTests {
    @Test func diagnosticsMetricLabelsAreDistinctInSimplifiedChinese() throws {
        let localizableURL = repositoryRoot
            .appendingPathComponent("Apps/VoidDisplay/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: localizableURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        #expect(localizedValue(for: "Recent Failures", in: strings) == "近期失败数")
        #expect(localizedValue(for: "Latest Failure Code", in: strings) == "最后失败代码")
    }

    @Test func diagnosticsUserFacingCopyDoesNotExposeSurfaceTerminology() throws {
        let globalForbiddenFragments = [
            "DisplaySurface",
            "Display Surface",
            "Display Surfaces",
            "Surface Detail",
            "Surface Kind",
            "Surface Count",
            "Surface 数量",
            "显示表面",
            "Display Identity",
            "Effective Capture Intent",
            "Lease Status",
            "Last Failure Code",
            "Preview Consumer",
            "LAN Web View Consumer",
            "Not managed",
            "未托管",
            "Managed virtual",
            "Managed Virtual Display",
            "托管虚拟",
            "托管虚拟显示器",
            "Physical auxiliary",
            "Physical Auxiliary Display",
            "物理辅助",
            "监看",
            "Desired Enabled",
            "desired enabled",
            "Restore Failed",
            "restore failed",
            "Needs attention",
            "Attention Needed",
            "期望启用",
            "恢复失败",
            "需要处理"
        ]
        let displaysHomeForbiddenFragments = globalForbiddenFragments + [
            "Consumer",
            "Lease",
            "Intent",
            "监听",
            "未监听"
        ]

        let localizableURL = repositoryRoot
            .appendingPathComponent("Apps/VoidDisplay/Resources/Localizable.xcstrings")
        let localizableContent = try String(contentsOf: localizableURL, encoding: .utf8)
        for fragment in displaysHomeForbiddenFragments {
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
            for fragment in globalForbiddenFragments {
                for literal in literals {
                    #expect(
                        literal.contains(fragment) == false,
                        "Forbidden user-facing copy '\(fragment)' found in \(fileURL.path): \(literal)"
                    )
                }
            }
        }

        let displaysHomeSourceFiles = [
            repositoryRoot.appendingPathComponent("Sources/VoidDisplayApp/Navigation/HomeView.swift"),
            repositoryRoot.appendingPathComponent("Sources/VoidDisplayApp/Navigation/DisplaySurfacePresentation.swift")
        ]
        for fileURL in displaysHomeSourceFiles {
            let literals = try swiftStringLiterals(in: fileURL)
            for fragment in displaysHomeForbiddenFragments {
                for literal in literals {
                    #expect(
                        literal.contains(fragment) == false,
                        "Forbidden Displays copy '\(fragment)' found in \(fileURL.path): \(literal)"
                    )
                }
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizedValue(for key: String, in strings: [String: Any]) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let simplifiedChinese = localizations?["zh-Hans"] as? [String: Any]
        let stringUnit = simplifiedChinese?["stringUnit"] as? [String: Any]
        return stringUnit?["value"] as? String
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
