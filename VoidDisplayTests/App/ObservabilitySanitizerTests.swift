import Foundation
import Testing
@testable import VoidDisplay

struct ObservabilitySanitizerTests {
    @Test func sanitizeTextRedactsHomePathsAndLocalIPs() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let input = "Open /Users/tester/Library/Logs via http://192.168.1.11:8080/display."

        let sanitized = sanitizer.sanitize(text: input)

        #expect(sanitized == "Open ~/Library/Logs via http://<redacted-ip>:8080/display.")
    }

    @Test func sanitizeMetadataAppliesValueRedaction() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let metadata = [
            "path": "/Users/tester/Documents/debug.json",
            "address": "10.0.0.8"
        ]

        let sanitized = sanitizer.sanitize(metadata: metadata)

        #expect(sanitized["path"] == "~/Documents/debug.json")
        #expect(sanitized["address"] == "<redacted-ip>")
    }

    @Test func sanitizeFileURLRewritesHomeDirectoryPrefix() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let url = URL(fileURLWithPath: "/Users/tester/Library/Application Support/VoidDisplay/support-bundle.zip")

        let sanitized = sanitizer.sanitize(fileURL: url)

        #expect(sanitized == "~/Library/Application Support/VoidDisplay/support-bundle.zip")
    }
}
