import Foundation
import VoidDisplayObservability
import Synchronization

package final class RelayProcessController: @unchecked Sendable {
    private struct State {
        var process: Process?
        var client: RelayHTTPClient?
        var controlToken: String?
        var startTask: Task<RelayHTTPClient, any Error>?
        var startGeneration: UInt64 = 0
        var expectedStop = false
        var onUnexpectedExit: (@Sendable () -> Void)?
    }

    private final class ReadyContinuation: @unchecked Sendable {
        private struct State {
            var isResolved = false
            var buffer = Data()
        }

        private let state = Mutex(State())
        private let continuation: CheckedContinuation<RelayReadyEvent, any Error>

        init(_ continuation: CheckedContinuation<RelayReadyEvent, any Error>) {
            self.continuation = continuation
        }

        func ingest(_ data: Data, decoder: JSONDecoder) -> Bool {
            state.withLock { state -> Bool in
                guard !state.isResolved else { return true }
                guard !data.isEmpty else {
                    state.isResolved = true
                    continuation.resume(throwing: RelayProcessError.exitedBeforeReady)
                    return true
                }
                state.buffer.append(data)
                guard let newlineIndex = state.buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                    return false
                }
                let lineData = state.buffer[..<newlineIndex]
                do {
                    let event = try decoder.decode(RelayReadyEvent.self, from: Data(lineData))
                    guard event.type == "ready" else {
                        throw RelayProcessError.invalidReadyLine
                    }
                    state.isResolved = true
                    continuation.resume(returning: event)
                } catch {
                    state.isResolved = true
                    continuation.resume(throwing: error)
                }
                return true
            }
        }

        func timeout() -> Bool {
            state.withLock { state -> Bool in
                guard !state.isResolved else { return false }
                state.isResolved = true
                continuation.resume(throwing: RelayProcessError.readyTimedOut)
                return true
            }
        }
    }

    private let state = Mutex(State())

    package init() {}

    package var onUnexpectedExit: (@Sendable () -> Void)? {
        get { state.withLock { $0.onUnexpectedExit } }
        set { state.withLock { $0.onUnexpectedExit = newValue } }
    }

    package nonisolated func client() async throws -> RelayHTTPClient {
        enum StartDecision {
            case client(RelayHTTPClient)
            case task(Task<RelayHTTPClient, any Error>, UInt64)
        }

        let decision = state.withLock { state -> StartDecision in
            if let client = state.client {
                return .client(client)
            }
            if let task = state.startTask {
                return .task(task, state.startGeneration)
            }
            state.startGeneration &+= 1
            let generation = state.startGeneration
            let task = Task<RelayHTTPClient, any Error> { [weak self] in
                guard let self else { throw RelayProcessError.controllerReleased }
                return try await self.startProcess(generation: generation)
            }
            state.startTask = task
            return .task(task, generation)
        }

        switch decision {
        case .client(let client):
            return client
        case .task(let task, let generation):
            do {
                let client = try await task.value
                let isCurrentStart = state.withLock {
                    if $0.startGeneration == generation {
                        $0.client = client
                        $0.startTask = nil
                        return true
                    }
                    return false
                }
                guard isCurrentStart else {
                    throw RelayProcessError.startSuperseded
                }
                return client
            } catch {
                state.withLock {
                    if $0.startGeneration == generation, $0.startTask != nil {
                        $0.startTask = nil
                        $0.client = nil
                    }
                }
                throw error
            }
        }
    }

    package nonisolated func stop() {
        let process = state.withLock { state -> Process? in
            state.expectedStop = true
            state.client = nil
            state.startTask?.cancel()
            state.startTask = nil
            state.startGeneration &+= 1
            let process = state.process
            state.process = nil
            state.controlToken = nil
            return process
        }
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
    }

    private nonisolated func startProcess(generation: UInt64) async throws -> RelayHTTPClient {
        try Task.checkCancellation()
        let binaryURL = try Self.resolveRelayBinaryURL()
        let controlToken = UUID().uuidString
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binaryURL
        process.arguments = [
            "--control-token", controlToken,
            "--listen-udp", ":0",
            "--loopback-http", "127.0.0.1:0",
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            self?.handleProcessExit(process: process, status: process.terminationStatus)
        }

        do {
            try state.withLock { state in
                guard state.startGeneration == generation, state.startTask != nil else {
                    throw RelayProcessError.startSuperseded
                }
                try Task.checkCancellation()
                state.expectedStop = false
                state.process = process
                state.controlToken = controlToken
                try process.run()
            }
            captureRelayStderr(stderr.fileHandleForReading)
            let ready = try await waitForReadyLine(stdout.fileHandleForReading)
            guard let baseURL = URL(string: ready.loopback) else {
                throw RelayProcessError.invalidReadyLoopback(ready.loopback)
            }
            AppLog.web.info("VoidDisplay relay ready at \(ready.loopback, privacy: .public).")
            return RelayHTTPClient(baseURL: baseURL, controlToken: controlToken)
        } catch {
            state.withLock { state in
                if state.startGeneration == generation {
                    state.expectedStop = true
                    state.process = nil
                    state.client = nil
                    state.controlToken = nil
                }
            }
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }

    private nonisolated func waitForReadyLine(_ handle: FileHandle) async throws -> RelayReadyEvent {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = ReadyContinuation(continuation)
            let decoder = JSONDecoder()
            handle.readabilityHandler = { readableHandle in
                let data = readableHandle.availableData
                let didFinish = waiter.ingest(data, decoder: decoder)
                if didFinish {
                    readableHandle.readabilityHandler = nil
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                if waiter.timeout() {
                    handle.readabilityHandler = nil
                }
            }
        }
    }

    private nonisolated func captureRelayStderr(_ handle: FileHandle) {
        handle.readabilityHandler = { readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8) else {
                readableHandle.readabilityHandler = nil
                return
            }
            AppLog.web.debug("VoidDisplay relay stderr: \(line, privacy: .public)")
        }
    }

    private nonisolated func handleProcessExit(process: Process, status: Int32) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.process === process else {
                return nil
            }
            let expectedStop = state.expectedStop
            state.process = nil
            state.client = nil
            state.controlToken = nil
            state.startTask = nil
            return expectedStop ? nil : state.onUnexpectedExit
        }
        if let callback {
            AppLog.web.error("VoidDisplay relay exited unexpectedly with status \(status, privacy: .public).")
            callback()
        }
    }

    private nonisolated static func resolveRelayBinaryURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["VOIDDISPLAY_RELAY_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "voiddisplay-relay", withExtension: nil) {
            return bundled
        }
        let debugPath = FileManager.default.currentDirectoryPath + "/.build/debug/voiddisplay-relay"
        if FileManager.default.isExecutableFile(atPath: debugPath) {
            return URL(fileURLWithPath: debugPath)
        }
        throw RelayProcessError.binaryNotFound
    }
}

package enum RelayProcessError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case controllerReleased
    case readyTimedOut
    case exitedBeforeReady
    case startSuperseded
    case invalidReadyLine
    case invalidReadyLoopback(String)

    package var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Relay binary was not found in the app bundle."
        case .controllerReleased:
            "Relay process controller was released before startup completed."
        case .readyTimedOut:
            "Relay process did not become ready in time."
        case .exitedBeforeReady:
            "Relay process exited before reporting readiness."
        case .startSuperseded:
            "Relay process startup was superseded."
        case .invalidReadyLine:
            "Relay process produced an invalid ready event."
        case .invalidReadyLoopback(let value):
            "Relay process reported an invalid loopback URL: \(value)"
        }
    }
}
