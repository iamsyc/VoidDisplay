import CoreGraphics
import Darwin
import Foundation
import Testing
import VoidDisplayVirtualDisplay
@testable import VoidDisplayCGVirtualDisplay

@MainActor
@Suite("Virtual display process lifecycle", .serialized)
struct VirtualDisplayProcessTests {
    @Test(arguments: [false, true])
    func exitingHostRestoresOnlySurvivorsBeforeReportingTermination(unexpectedExit: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("host-pid")
        let quotedPIDPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let firstJSON = try readyJSON(displayID: 9001)
        let secondJSON = try readyJSON(displayID: 9002)
        let script = """
        printf '%s\\n' "$$" >\(quotedPIDPath)
        read request
        case "$request" in
          *'"serialNumber":32'*) printf '%s\\n' '\(secondJSON)' ;;
          *) printf '%s\\n' '\(firstJSON)' ;;
        esac
        while IFS= read -r line; do :; done
        """
        let modes = FakeModePreserver()
        let driver = CGVirtualDisplayRuntimeDriver(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], modePreserver: modes
        )
        var first: (any VirtualDisplayRuntimeHandling)? = try await driver.createRuntimeDisplay(
            descriptor: descriptor, onTermination: {}
        )
        #expect(first?.displayID == 9001)
        // Preserve a mode chosen outside the app, rather than pinning the creation mode.
        let userMode = VirtualDisplayRuntimeDisplayMode(
            id: 3, width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60
        )
        modes.current[9001] = userMode
        let secondDescriptor = VirtualDisplayRuntimeDescriptor(
            name: "Second", serialNumber: 32, physicalSize: descriptor.physicalSize,
            maximumPixelDimensions: descriptor.maximumPixelDimensions, modes: descriptor.modes
        )
        var terminated = false
        var second: (any VirtualDisplayRuntimeHandling)? = try await driver.createRuntimeDisplay(
            descriptor: secondDescriptor,
            onTermination: {
                #expect(modes.restored.last?.map(\.displayID) == [9001])
                #expect(modes.restored.last?.first?.mode == userMode)
                terminated = true
            }
        )
        #expect(second?.displayID == 9002)
        #expect(modes.captured.map { $0.map(\.displayID) } == [[], [9001]])
        if unexpectedExit {
            let text = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(pid, SIGTERM) == 0)
        } else {
            second = nil
        }
        #expect(await waitUntil { terminated })
        #expect(modes.current[9001] == userMode)
        second = nil
        first = nil
    }

    @Test
    func terminationWaitsForNativeDisconnectionBeforeRestoringOrCreating() async throws {
        let modes = FakeModePreserver()
        let driver = CGVirtualDisplayRuntimeDriver(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", try readyScript()], modePreserver: modes
        )
        var terminated = false
        var handle: (any VirtualDisplayRuntimeHandling)? = try await driver.createRuntimeDisplay(
            descriptor: descriptor, onTermination: { terminated = true }
        )
        #expect(handle?.displayID == 9001)
        modes.suspendDisconnection = true
        handle = nil
        let capturesBeforeNextCreate = modes.captured.count
        #expect(await waitUntil { modes.disconnectionContinuation != nil })
        #expect(modes.restored.isEmpty)
        #expect(!terminated)

        var createdAgain = false
        let next = Task {
            let result = try await driver.createRuntimeDisplay(descriptor: descriptor, onTermination: {})
            createdAgain = true
            return result
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!createdAgain)
        #expect(modes.captured.count == capturesBeforeNextCreate)
        modes.suspendDisconnection = false
        modes.disconnectionContinuation?.resume()
        modes.disconnectionContinuation = nil
        let nextHandle = try await next.value
        #expect(await waitUntil { terminated })
        #expect(modes.waitedSerialNumbers.first == descriptor.serialNumber)
        #expect(!modes.restored.isEmpty)
        withExtendedLifetime(nextHandle) {}
    }

    @Test(arguments: [0, 8192])
    func releasingHandleClosesHostInputAndReportsTermination(leadingWhitespace: Int) async throws {
        var terminated = false
        var handle: (any VirtualDisplayRuntimeHandling)? = try await driver(
            script: try readyScript(leadingWhitespace: leadingWhitespace)
        ).createRuntimeDisplay(
            descriptor: descriptor, onTermination: { terminated = true }
        )
        #expect(handle?.displayID == 9001)
        #expect(handle?.serialNum == 31)
        #expect(!terminated)
        handle = nil
        #expect(await waitUntil { terminated })
    }

    @Test
    func overlappingTeardownsPreserveModesAndBlockCreateUntilEveryDisconnection() async throws {
        let responses = try (31...34).map { serial in
            "*'\"name\":\"Display \(serial)\"'*) printf '%s\\n' '\(try readyJSON(displayID: UInt32(9001 + serial - 31)))' ;;"
        }.joined(separator: "\n")
        let script = "read request; case \"$request\" in\n\(responses)\nesac; while IFS= read -r line; do :; done"
        let modes = FakeModePreserver()
        let driver = CGVirtualDisplayRuntimeDriver(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], modePreserver: modes
        )
        func descriptorForSerial(_ serial: UInt32) -> VirtualDisplayRuntimeDescriptor {
            .init(name: "Display \(serial)", serialNumber: serial, physicalSize: descriptor.physicalSize,
                  maximumPixelDimensions: descriptor.maximumPixelDimensions, modes: descriptor.modes)
        }
        var firstTerminated = false
        var first: (any VirtualDisplayRuntimeHandling)? = try await driver.createRuntimeDisplay(
            descriptor: descriptorForSerial(31), onTermination: { firstTerminated = true }
        )
        var second: (any VirtualDisplayRuntimeHandling)? = try await driver.createRuntimeDisplay(
            descriptor: descriptorForSerial(32), onTermination: {}
        )
        let survivor = try await driver.createRuntimeDisplay(descriptor: descriptorForSerial(33), onTermination: {})
        #expect(first?.displayID == 9001)
        #expect(second?.displayID == 9002)
        #expect(survivor.displayID == 9003)
        let userMode = VirtualDisplayRuntimeDisplayMode(
            id: 3, width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60
        )
        let transitionalMode = VirtualDisplayRuntimeDisplayMode(
            id: 4, width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60
        )
        modes.current[9003] = userMode
        modes.suspendedSerialNumbers = [31, 32]
        defer {
            modes.suspendedSerialNumbers.removeAll()
            for continuation in modes.disconnectionContinuations.values { continuation.resume() }
            modes.disconnectionContinuations.removeAll()
        }
        first = nil
        try #require(await waitUntil { modes.disconnectionContinuations[31] != nil })
        let capturesBeforeSecondRelease = modes.captured.count
        // The first native removal has changed the survivor, but restoration is still pending.
        modes.current[9003] = transitionalMode
        var createStarted = false
        let next = Task {
            createStarted = true
            return try await driver.createRuntimeDisplay(descriptor: descriptorForSerial(34), onTermination: {})
        }
        #expect(await waitUntil { createStarted })
        second = nil
        #expect(await waitUntil { modes.disconnectionContinuations[32] != nil })
        #expect(modes.captured.count == capturesBeforeSecondRelease)
        let capturesBeforeFirstSettlement = modes.captured.count
        modes.suspendedSerialNumbers.remove(31)
        modes.disconnectionContinuations.removeValue(forKey: 31)?.resume()
        #expect(await waitUntil { firstTerminated })
        // A create already awaiting A must also discover B's subsequently registered settlement.
        let capturedBeforeSecondSettlement = await waitUntil {
            modes.captured.count > capturesBeforeFirstSettlement
        }
        #expect(!capturedBeforeSecondSettlement)
        #expect(modes.current[9003] == userMode)
        modes.suspendedSerialNumbers.remove(32)
        modes.disconnectionContinuations.removeValue(forKey: 32)?.resume()
        let nextHandle = try await next.value
        #expect(nextHandle.displayID == 9004)
        #expect(modes.current[9003] == userMode)
        withExtendedLifetime((survivor, nextHandle)) {}
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

    @Test
    func failedCreationBlocksNextCreateBeforeHostTermination() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".ai-tmp/failed-create-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func quoted(_ name: String) -> String {
            "'" + directory.appendingPathComponent(name).path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        let releaseMarker = directory.appendingPathComponent("release-first-host")
        let failed = String(decoding: try JSONEncoder().encode(VirtualDisplayHostResponse.failed("mode readback failed")), as: UTF8.self)
        let script = """
        read request
        if mkdir \(quoted("first-request")) 2>/dev/null; then
            trap '' TERM
            printf '%s\\n' "$$" >\(quoted("first-pid"))
            printf '%s\\n' '\(failed)'
            while [ ! -f \(quoted("release-first-host")) ]; do /bin/sleep 0.01; done
            exit 1
        fi
        printf '%s\\n' "$$" >\(quoted("second-pid"))
        printf '%s\\n' '\(try readyJSON(displayID: 9002))'
        while IFS= read -r line; do :; done
        """
        let modes = FakeModePreserver()
        modes.suspendedSerialNumbers = [descriptor.serialNumber]
        defer {
            modes.suspendedSerialNumbers.removeAll()
            for continuation in modes.disconnectionContinuations.values { continuation.resume() }
            modes.disconnectionContinuations.removeAll()
            for name in ["first-pid", "second-pid"] {
                if let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    _ = kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let driver = CGVirtualDisplayRuntimeDriver(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], modePreserver: modes
        )
        var firstTerminated = false
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await driver.createRuntimeDisplay(descriptor: descriptor, onTermination: { firstTerminated = true })
        }
        let pidText = try String(contentsOf: directory.appendingPathComponent("first-pid"), encoding: .utf8)
        let firstPID = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(kill(firstPID, 0) == 0)
        #expect(!firstTerminated)
        let capturesBeforeNextCreate = modes.captured.count
        var createdAgain = false
        var secondTerminated = false
        var nextHandle: (any VirtualDisplayRuntimeHandling)?
        let next = Task {
            nextHandle = try await driver.createRuntimeDisplay(descriptor: descriptor, onTermination: { secondTerminated = true })
            createdAgain = true
        }
        defer { next.cancel() }
        // Do not wait for a termination callback before starting the next create.
        // The failed host stays alive until the assertions below have observed the boundary.
        #expect(await waitUntil {
            modes.captured.count > capturesBeforeNextCreate || modes.disconnectionContinuations[descriptor.serialNumber] != nil
        })
        #expect(kill(firstPID, 0) == 0)
        #expect(modes.captured.count == capturesBeforeNextCreate)
        #expect(!createdAgain)

        try Data().write(to: releaseMarker)
        #expect(await waitUntil { kill(firstPID, 0) != 0 })
        #expect(await waitUntil { modes.disconnectionContinuations[descriptor.serialNumber] != nil })
        modes.suspendedSerialNumbers.remove(descriptor.serialNumber)
        modes.disconnectionContinuations.removeValue(forKey: descriptor.serialNumber)?.resume()
        try await next.value
        #expect(nextHandle?.displayID == 9002)
        #expect(await waitUntil { firstTerminated })
        nextHandle = nil
        #expect(await waitUntil { secondTerminated })
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

    private func readyScript(leadingWhitespace: Int = 0) throws -> String {
        let json = String(repeating: " ", count: leadingWhitespace) + (try readyJSON(displayID: 9001))
        return "read request; printf '%s\\n' '\(json)'; while IFS= read -r line; do :; done"
    }

    private func readyJSON(displayID: CGDirectDisplayID) throws -> String {
        let response = VirtualDisplayHostResponse.ready(displayID: displayID, mode: .init(
            id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60
        ))
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class FakeModePreserver: VirtualDisplayModePreserving {
    var current: [CGDirectDisplayID: VirtualDisplayRuntimeDisplayMode] = [:]
    var captured: [[PreservedVirtualDisplayMode]] = []
    var restored: [[PreservedVirtualDisplayMode]] = []
    var waitedSerialNumbers: [UInt32] = []
    var suspendDisconnection = false
    var disconnectionContinuation: CheckedContinuation<Void, Never>?
    var suspendedSerialNumbers: Set<UInt32> = []
    var disconnectionContinuations: [UInt32: CheckedContinuation<Void, Never>] = [:]

    func waitForDisconnection(serialNumber: UInt32) async throws {
        waitedSerialNumbers.append(serialNumber)
        if suspendDisconnection {
            await withCheckedContinuation { disconnectionContinuation = $0 }
        } else if suspendedSerialNumbers.contains(serialNumber) {
            await withCheckedContinuation { disconnectionContinuations[serialNumber] = $0 }
        }
    }

    func capture(_ displays: [PreservedVirtualDisplayMode]) throws -> [PreservedVirtualDisplayMode] {
        captured.append(displays)
        return displays.map {
            .init(displayID: $0.displayID, serialNumber: $0.serialNumber, mode: current[$0.displayID] ?? $0.mode)
        }
    }

    func restore(_ displays: [PreservedVirtualDisplayMode]) throws {
        restored.append(displays)
        for display in displays { current[display.displayID] = display.mode }
    }
}
