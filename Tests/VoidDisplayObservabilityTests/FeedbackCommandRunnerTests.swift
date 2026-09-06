@testable import VoidDisplayObservability
import Foundation
import Testing

struct FeedbackCommandRunnerTests {
    @Test(arguments: [16 * 1024, 256 * 1024])
    func drainsOutputWhileCommandRuns(byteCount: Int) throws {
        let output = try #require(FeedbackBundleExporter.runCommand(
            "/bin/dd", arguments: ["if=/dev/zero", "bs=\(byteCount)", "count=1"], timeout: 2
        ))
        #expect(output.utf8.count == byteCount)
    }

    @Test func discardsLargeStandardError() {
        let output = FeedbackBundleExporter.runCommand(
            "/bin/sh", arguments: ["-c", "/bin/dd if=/dev/zero bs=262144 count=4 >&2; printf '完成\\n'"], timeout: 2
        )
        #expect(output == "完成\n")
    }

    @Test func retainsBoundedUTF8Tail() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".ai-tmp/command-tail-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt")
        let content = String(repeating: "中文日志\n", count: 80_000) + "末尾标记\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
        let output = try #require(FeedbackBundleExporter.runCommand("/bin/cat", arguments: [file.path], timeout: 2))
        #expect(output.utf8.count <= 512 * 1024)
        #expect(output.hasSuffix(String(content.suffix(20_000))))
        #expect(!output.contains("�"), "Byte truncation must preserve complete UTF-8 characters")
    }

    @Test(arguments: [false, true])
    func timeoutTerminatesCommand(ignoresTermination: Bool) {
        let started = Date()
        let result = FeedbackBundleExporter.runCommand(
            ignoresTermination ? "/bin/sh" : "/bin/sleep",
            arguments: ignoresTermination ? ["-c", "trap '' TERM; exec /bin/sleep 5"] : ["5"], timeout: 0.1
        )
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func failedEmptyAndUnlaunchableCommandsReturnNil() {
        #expect(FeedbackBundleExporter.runCommand("/usr/bin/false", arguments: [], timeout: 2) == nil)
        #expect(FeedbackBundleExporter.runCommand("/usr/bin/true", arguments: [], timeout: 2) == nil)
        #expect(FeedbackBundleExporter.runCommand("/voiddisplay-missing-test-executable", arguments: [], timeout: 2) == nil)
    }
}
