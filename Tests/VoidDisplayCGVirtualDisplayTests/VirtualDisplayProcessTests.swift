import CoreGraphics
import Darwin
import Foundation
import Testing
import VoidDisplayVirtualDisplay
@testable import VoidDisplayCGVirtualDisplay

@MainActor
@Suite("Virtual display process lifecycle", .serialized)
struct VirtualDisplayProcessTests {
    @Test func releasingHandleClosesHostInputAndReportsTermination() async throws {
        var terminated = false
        var handle: (any VirtualDisplayRuntimeHandling)? = try await driver(script: try readyScript()).createRuntimeDisplay(
            descriptor: descriptor, onTermination: { terminated = true }
        )
        #expect(handle?.displayID == 9001)
        #expect(handle?.serialNum == 31)
        #expect(!terminated)
        handle = nil
        #expect(await waitUntil { terminated })
    }

    @Test func unexpectedHostExitReportsTermination() async throws {
        var terminated = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("host-pid")
        let quotedPIDPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        // Keep the host alive until creation finishes before simulating an unexpected exit.
        let script = "printf '%s\\n' \"$$\" >\(quotedPIDPath); \(try readyScript())"
        let handle = try await driver(script: script).createRuntimeDisplay(
            descriptor: descriptor, onTermination: { terminated = true }
        )
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let hostPID = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(hostPID > 0)
        try #require(!terminated)
        #expect(kill(hostPID, SIGTERM) == 0)
        #expect(await waitUntil { terminated })
        withExtendedLifetime(handle) {}
    }

    @Test(arguments: ["printf 'invalid\\n'", "exit 1"])
    func invalidOrMissingReadyResponseFailsAndReapsHost(script: String) async {
        var terminated = false
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await driver(script: "read request; " + script).createRuntimeDisplay(
                descriptor: descriptor, onTermination: { terminated = true }
            )
        }
        #expect(await waitUntil { terminated })
    }

    @Test func earlyExitDuringRequestWriteDoesNotTerminateParent() async {
        // Exceed pipe capacity so the peer closes while the request is still being written.
        let largeRequest = VirtualDisplayRuntimeDescriptor(
            name: String(repeating: "x", count: 131_072), serialNumber: 31,
            physicalSize: descriptor.physicalSize, maximumPixelDimensions: descriptor.maximumPixelDimensions,
            modes: descriptor.modes
        )
        var terminated = false
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await driver(script: "exit 1").createRuntimeDisplay(
                descriptor: largeRequest, onTermination: { terminated = true }
            )
        }
        #expect(await waitUntil { terminated })
    }

    @Test func readyTimeoutTerminatesHost() async {
        var terminated = false
        let start = ContinuousClock.now
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await driver(script: "read request; exec sleep 60", timeout: .milliseconds(100)).createRuntimeDisplay(
                descriptor: descriptor, onTermination: { terminated = true }
            )
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(await waitUntil { terminated })
    }

    @Test func timeoutIncludesBlockedRequestWrite() async {
        let largeRequest = VirtualDisplayRuntimeDescriptor(
            name: String(repeating: "x", count: 131_072), serialNumber: 31,
            physicalSize: descriptor.physicalSize, maximumPixelDimensions: descriptor.maximumPixelDimensions,
            modes: descriptor.modes
        )
        var terminated = false
        let start = ContinuousClock.now
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await driver(script: "exec sleep 60", timeout: .milliseconds(100)).createRuntimeDisplay(
                descriptor: largeRequest, onTermination: { terminated = true }
            )
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(await waitUntil { terminated })
    }

    @Test func cancellationTerminatesHostBeforeReady() async throws {
        var terminated = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyMarker = directory.appendingPathComponent("request-read")
        let quotedPath = "'" + readyMarker.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let task = Task {
            try await driver(script: "read request; touch \(quotedPath); exec sleep 60").createRuntimeDisplay(
                descriptor: descriptor, onTermination: { terminated = true }
            )
        }
        defer { task.cancel() }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: readyMarker.path) })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await waitUntil { terminated })
    }

    private var descriptor: VirtualDisplayRuntimeDescriptor {
        .init(name: "Test", serialNumber: 31, physicalSize: CGSize(width: 310, height: 174),
              maximumPixelDimensions: .init(width: 1920, height: 1080),
              modes: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false)])
    }

    private func driver(script: String, timeout: Duration = .seconds(5)) -> CGVirtualDisplayRuntimeDriver {
        CGVirtualDisplayRuntimeDriver(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], readyTimeout: timeout)
    }

    private func readyScript() throws -> String {
        let response = VirtualDisplayHostResponse.ready(displayID: 9001, mode: .init(
            id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60
        ))
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        return "read request; printf '%s\\n' '\(json)'; while IFS= read -r line; do :; done"
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
