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

    package init(
        executableURL: URL? = Bundle.main.url(forAuxiliaryExecutable: "VoidDisplayHost"),
        arguments: [String] = [],
        readyTimeout: Duration = .seconds(5)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.readyTimeout = readyTimeout
    }

    package func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling {
        try Task.checkCancellation()
        guard let executableURL else { throw VirtualDisplayOperationError.creationFailed }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in Task { @MainActor in onTermination() } }
        var committed = false
        defer {
            try? output.fileHandleForReading.close()
            if !committed {
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
            var data = try JSONEncoder().encode(descriptor)
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
            guard case .ready(let displayID, _) = response, displayID != 0, process.isRunning else {
                AppLog.virtualDisplay.error("Virtual display host did not become ready: \(String(describing: response), privacy: .public)")
                throw VirtualDisplayOperationError.creationFailed
            }
            committed = true
            return VirtualDisplayProcessHandle(serialNum: descriptor.serialNumber, displayID: displayID,
                                               process: process, lifetimeInput: input.fileHandleForWriting)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            AppLog.virtualDisplay.error("Virtual display host creation failed: \(String(describing: error), privacy: .public)")
            throw VirtualDisplayOperationError.creationFailed
        }
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
private final class VirtualDisplayProcessHandle: VirtualDisplayRuntimeHandling {
    let serialNum: UInt32
    let displayID: CGDirectDisplayID
    private let process: Process
    private let lifetimeInput: FileHandle

    init(serialNum: UInt32, displayID: CGDirectDisplayID, process: Process, lifetimeInput: FileHandle) {
        self.serialNum = serialNum
        self.displayID = displayID
        self.process = process
        self.lifetimeInput = lifetimeInput
    }

    deinit {
        // Releasing the handle ends the owning process, including native mode-selection resources.
        try? lifetimeInput.close()
    }
}
