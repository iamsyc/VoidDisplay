import AppKit
import CoreGraphics
import Darwin
import Foundation
import VoidDisplayCGVirtualDisplay
import VoidDisplayVirtualDisplay

/// Explicit native acceptance only. Ordinary tests never launch this executable.
@main @MainActor
struct DisplayHostAcceptance {
    struct Display: Codable, Equatable {
        let id: CGDirectDisplayID
        let serial: UInt32
        let isMain: Bool
        let mode: VirtualDisplayRuntimeDisplayMode?
    }

    struct Scenario: Codable {
        let hiDPI: Bool
        let closingFirst: Bool
        let unexpectedExit: Bool
        let before: [Display]
        let after: [Display]
    }

    struct Evidence: Codable {
        var status = "failed"
        var failure: String?
        let baseline: [Display]
        var scenarios: [Scenario] = []
        var final: [Display] = []
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func inspect() -> [Display] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map {
            Display(id: $0, serial: CGDisplaySerialNumber($0), isMain: CGDisplayIsMain($0) != 0,
                    mode: CGDisplayCopyDisplayMode($0).map(SystemVirtualDisplayModePreserver.snapshot))
        }.sorted { $0.id < $1.id }
    }

    static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure("Native state did not converge: \(inspect())") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func childPIDs() throws -> Set<Int32> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid()), "-x", "VoidDisplayHost"]
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus <= 1 else { throw Failure("Could not identify owned test host") }
        return Set(text.split(separator: "\n").compactMap { Int32($0) })
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await runAcceptance() }
        NSApplication.shared.run()
    }

    static func runAcceptance() async {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: DisplayHostAcceptance <signed-host-path> <evidence.json>")
            exit(2)
        }
        var evidence = Evidence(baseline: inspect())
        var handles: [Int: any VirtualDisplayRuntimeHandling] = [:]
        do {
            guard !evidence.baseline.contains(where: { [4_000_932, 4_000_933].contains($0.serial) }) else {
                throw Failure("Acceptance serial already in use")
            }
            for hiDPI in [false, true] {
                for closingFirst in [false, true] {
                    for unexpectedExit in [false, true] {
                        let driver = CGVirtualDisplayRuntimeDriver(executableURL: URL(fileURLWithPath: CommandLine.arguments[1]))
                        var terminated: Set<Int> = []
                        var pids: [Int: Int32] = [:]
                        var expected = evidence.baseline
                        for index in 0...1 {
                            let previousPIDs = try childPIDs()
                            let descriptor = VirtualDisplayRuntimeDescriptor(
                                name: "VoidDisplay native acceptance", serialNumber: 4_000_932 + UInt32(index),
                                physicalSize: CGSize(width: 310, height: 174),
                                maximumPixelDimensions: .init(width: hiDPI ? 3840 : 1920, height: hiDPI ? 2160 : 1080),
                                modes: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: hiDPI)]
                            )
                            handles[index] = try await driver.createRuntimeDisplay(
                                descriptor: descriptor, onTermination: { terminated.insert(index) }
                            )
                            let newPIDs = try childPIDs().subtracting(previousPIDs)
                            guard newPIDs.count == 1, let pid = newPIDs.first else { throw Failure("Ambiguous test host") }
                            pids[index] = pid
                            let actual = inspect()
                            guard let added = actual.first(where: { $0.id == handles[index]?.displayID }),
                                  added.mode?.width == 1920, added.mode?.height == 1080,
                                  added.mode?.pixelWidth == (hiDPI ? 3840 : 1920),
                                  added.mode?.pixelHeight == (hiDPI ? 2160 : 1080),
                                  actual.filter({ $0.id != added.id }) == expected else {
                                throw Failure("Creation changed a peer or selected the wrong mode: \(actual)")
                            }
                            expected = actual
                        }
                        let closing = closingFirst ? 0 : 1
                        let closingID = handles[closing]?.displayID
                        if unexpectedExit, let pid = pids[closing] {
                            guard kill(pid, SIGTERM) == 0 else { throw Failure("Could not terminate owned test host") }
                        } else {
                            handles[closing] = nil
                        }
                        try await waitUntil { terminated.contains(closing) }
                        let survivors = expected.filter { $0.id != closingID }
                        try await waitUntil { inspect() == survivors }
                        evidence.scenarios.append(.init(hiDPI: hiDPI, closingFirst: closingFirst,
                                                        unexpectedExit: unexpectedExit, before: expected, after: inspect()))
                        handles.removeAll()
                        try await waitUntil { terminated.count == 2 && inspect() == evidence.baseline }
                    }
                }
            }
            evidence.status = "passed"
        } catch {
            evidence.failure = String(describing: error)
        }
        handles.removeAll()
        do { try await waitUntil { inspect() == evidence.baseline } }
        catch { evidence.status = "failed"; evidence.failure = "\(evidence.failure ?? ""); cleanup: \(error)" }
        evidence.final = inspect()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        } catch { print(error); exit(1) }
        print("Native driver acceptance: \(evidence.scenarios.count)/8; \(evidence.status). \(evidence.failure ?? "")")
        exit(evidence.status == "passed" ? 0 : 1)
    }
}
