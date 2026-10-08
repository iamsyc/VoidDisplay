import CoreGraphics
import Darwin
import Foundation
import OSLog
import VoidDisplayObservability
import VoidDisplayVirtualDisplay

@MainActor
package final class CGVirtualDisplayRuntimeDriver: VirtualDisplayRuntimeDriving {
    private let executableURL: URL?
    private let arguments: [String]
    private let readyTimeout: Duration
    private let modePreserver: any VirtualDisplayModePreserving
    private var ownedModes: [UUID: PreservedVirtualDisplayMode] = [:]
    private var pendingSettlements: [UUID: Task<Void, Never>] = [:]

    package init(
        executableURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "VoidDisplayHost"),
        arguments: [String] = [],
        readyTimeout: Duration = .seconds(5),
        modePreserver: any VirtualDisplayModePreserving = SystemVirtualDisplayModePreserver()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.readyTimeout = readyTimeout
        self.modePreserver = modePreserver
    }

    package func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling {
        try Task.checkCancellation()
        guard let executableURL else { throw VirtualDisplayOperationError.creationFailed }
        var settledTokens: Set<UUID> = []
        while let (token, settlement) = pendingSettlements.first(where: { !settledTokens.contains($0.key) }) {
            await settlement.value
            settledTokens.insert(token)
        }
        try Task.checkCancellation()
        // Capture the user's current modes before changing native topology, including
        // choices made outside the app. Only live displays owned by this driver participate.
        try refreshOwnedModes()
        let request = VirtualDisplayHostRequest(descriptor: descriptor, preservedModes: orderedOwnedModes)
        let token = UUID()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let termination = HostTerminationObservation()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                termination.isObserved = true
                await self?.hostTerminated(token: token, serialNumber: descriptor.serialNumber)
                onTermination()
            }
        }
        var committed = false
        defer {
            try? output.fileHandleForReading.close()
            if !committed {
                if process.processIdentifier > 0, !termination.isObserved {
                    _ = settlement(token: token, serialNumber: descriptor.serialNumber)
                }
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
            }
        }
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            // A host may exit before reading its request. Convert EPIPE into a creation error
            // instead of allowing SIGPIPE to terminate the main app.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw VirtualDisplayOperationError.creationFailed
            }
            var data = try JSONEncoder().encode(request)
            data.append(0x0A)
            let timeout = Task {
                try await Task.sleep(for: readyTimeout)
                if process.isRunning { process.terminate() }
            }
            defer { timeout.cancel() }
            let response = try await withTaskCancellationHandler {
                try await Self.exchangeRequest(data, input: input.fileHandleForWriting, output: output.fileHandleForReading)
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            try Task.checkCancellation()
            guard case .ready(let displayID, let mode) = response, displayID != 0, process.isRunning else {
                AppLog.virtualDisplay.error("Virtual display host did not become ready: \(String(describing: response), privacy: .public)")
                throw VirtualDisplayOperationError.creationFailed
            }
            ownedModes[token] = .init(displayID: displayID, serialNumber: descriptor.serialNumber, mode: mode)
            committed = true
            return VirtualDisplayProcessHandle(serialNum: descriptor.serialNumber, displayID: displayID,
                                               process: process, lifetimeInput: input.fileHandleForWriting,
                                               onRelease: { self.prepareForRelease(token: token) })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            AppLog.virtualDisplay.error("Virtual display host creation failed: \(String(describing: error), privacy: .public)")
            throw VirtualDisplayOperationError.creationFailed
        }
    }

    private var orderedOwnedModes: [PreservedVirtualDisplayMode] {
        ownedModes.values.sorted { $0.displayID < $1.displayID }
    }

    private func refreshOwnedModes() throws {
        let captured = try modePreserver.capture(orderedOwnedModes)
        for (token, previous) in ownedModes {
            if let current = captured.first(where: { $0.displayID == previous.displayID }) {
                ownedModes[token] = current
            }
        }
    }

    private func prepareForRelease(token: UUID) {
        guard let removed = ownedModes.removeValue(forKey: token) else { return }
        // Consecutive releases must retain the baseline from before native reconfiguration.
        if pendingSettlements.isEmpty {
            do {
                try refreshOwnedModes()
            } catch {
                AppLog.virtualDisplay.error("Could not snapshot surviving display modes before teardown: \(String(describing: error), privacy: .public)")
            }
        }
        _ = settlement(token: token, serialNumber: removed.serialNumber)
    }

    private func hostTerminated(token: UUID, serialNumber: UInt32) async {
        ownedModes[token] = nil
        await settlement(token: token, serialNumber: serialNumber).value
        pendingSettlements[token] = nil
    }

    private func settlement(token: UUID, serialNumber: UInt32) -> Task<Void, Never> {
        if let pending = pendingSettlements[token] { return pending }
        let pending = Task {
            do {
                // Process exit precedes WindowServer's disconnection. Restore only after
                // native removal, and keep new creates from capturing transitional modes.
                try await modePreserver.waitForDisconnection(serialNumber: serialNumber)
                try modePreserver.restore(orderedOwnedModes)
            } catch {
                AppLog.virtualDisplay.error("Could not settle surviving display modes after teardown: \(String(describing: error), privacy: .public)")
            }
        }
        pendingSettlements[token] = pending
        return pending
    }

    private nonisolated static func exchangeRequest(
        _ request: Data, input: FileHandle, output: FileHandle
    ) async throws -> VirtualDisplayHostResponse {
        try await withCheckedThrowingContinuation { continuation in
            // Pipe I/O can block. Keep cooperative workers available for timeout and cancellation tasks.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try input.write(contentsOf: request)
                    var response = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw VirtualDisplayOperationError.creationFailed }
                        response.append(contentsOf: buffer.prefix(count))
                        if let newline = response.firstIndex(of: 0x0A) {
                            return try JSONDecoder().decode(VirtualDisplayHostResponse.self, from: response.prefix(upTo: newline))
                        }
                    }
                })
            }
        }
    }
}

@MainActor
package func makeVirtualDisplayRuntimeDriver() -> any VirtualDisplayRuntimeDriving {
    CGVirtualDisplayRuntimeDriver()
}

@MainActor
private final class HostTerminationObservation {
    var isObserved = false
}

@MainActor
private final class VirtualDisplayProcessHandle: VirtualDisplayRuntimeHandling {
    let serialNum: UInt32
    let displayID: CGDirectDisplayID
    private let process: Process
    private let lifetimeInput: FileHandle
    private let onRelease: @MainActor () -> Void

    init(serialNum: UInt32, displayID: CGDirectDisplayID, process: Process, lifetimeInput: FileHandle,
         onRelease: @escaping @MainActor () -> Void) {
        self.serialNum = serialNum
        self.displayID = displayID
        self.process = process
        self.lifetimeInput = lifetimeInput
        self.onRelease = onRelease
    }

    deinit {
        MainActor.assumeIsolated { onRelease() }
        // Releasing the handle ends the owning process, including native mode-selection resources.
        try? lifetimeInput.close()
    }
}
