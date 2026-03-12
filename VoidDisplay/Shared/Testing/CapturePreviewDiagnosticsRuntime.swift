import AppKit
import CoreGraphics
import Foundation

struct CapturePreviewDiagnosticsConfiguration: Sendable {
    let sourcePixelSize: CGSize
    let targetContentWidth: CGFloat?
    let replayImageURL: URL?
    let recordDirectoryURL: URL?
}

enum CapturePreviewDiagnosticsRuntime {
    nonisolated static let sourceSizeEnvironmentKey = "VOIDDISPLAY_CAPTURE_PREVIEW_SOURCE_SIZE"
    nonisolated static let targetContentWidthEnvironmentKey = "VOIDDISPLAY_CAPTURE_PREVIEW_TARGET_CONTENT_WIDTH"
    nonisolated static let replayImagePathEnvironmentKey = "VOIDDISPLAY_CAPTURE_PREVIEW_REPLAY_IMAGE_PATH"
    nonisolated static let recordDirectoryPathEnvironmentKey = "VOIDDISPLAY_CAPTURE_PREVIEW_RECORD_DIRECTORY"

    nonisolated static var isPreviewDiagnosticsScenario: Bool {
        UITestRuntime.isEnabled && UITestRuntime.scenario == .capturePreviewDiagnostics
    }

    nonisolated static var shouldAutoOpenPreviewWindow: Bool {
        isPreviewDiagnosticsScenario
    }

    nonisolated static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CapturePreviewDiagnosticsConfiguration? {
        let replayImageURL: URL?
        if let path = environment[replayImagePathEnvironmentKey], !path.isEmpty {
            replayImageURL = URL(fileURLWithPath: path)
        } else {
            replayImageURL = nil
        }

        let sourcePixelSize = parsedSize(from: environment[sourceSizeEnvironmentKey])
            ?? replayImageSize(from: replayImageURL)
            ?? CGSize(width: 2560, height: 1600)

        let targetContentWidth: CGFloat?
        if let rawWidth = environment[targetContentWidthEnvironmentKey],
           let width = Double(rawWidth) {
            targetContentWidth = CGFloat(width)
        } else {
            targetContentWidth = nil
        }

        let recordDirectoryURL: URL?
        if let path = environment[recordDirectoryPathEnvironmentKey], !path.isEmpty {
            recordDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            recordDirectoryURL = nil
        }

        return CapturePreviewDiagnosticsConfiguration(
            sourcePixelSize: sourcePixelSize,
            targetContentWidth: targetContentWidth,
            replayImageURL: replayImageURL,
            recordDirectoryURL: recordDirectoryURL
        )
    }

    nonisolated static func parsedSize(from rawValue: String?) -> CGSize? {
        guard let rawValue else { return nil }
        let separators: [Character] = ["x", "X", "×", ","]
        guard let separator = separators.first(where: rawValue.contains) else { return nil }
        let parts = rawValue.split(separator: separator, maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let width = Double(parts[0]), width > 0,
              let height = Double(parts[1]), height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func replayImageSize(from url: URL?) -> CGSize? {
        guard let url,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}
