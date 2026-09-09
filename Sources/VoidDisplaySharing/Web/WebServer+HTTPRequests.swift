import Foundation
import Network

extension WebServer {
    struct PendingHTTPRequest {
        let connection: NWConnection
        let deadlineTask: Task<Void, Never>
    }

    func acceptHTTPRequest(on connection: NWConnection) {
        // Admission and teardown share MainActor ownership, including queued accepts after stop.
        guard listener != nil, pendingHTTPRequests.count < 32 else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        let deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let pending = self?.pendingHTTPRequests.removeValue(forKey: key) else { return }
            pending.connection.cancel()
        }
        pendingHTTPRequests[key] = PendingHTTPRequest(connection: connection, deadlineTask: deadlineTask)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state, for: connection)
            }
        }
        connection.start(queue: networkQueue)
        let accumulator = HTTPRequestAccumulator(
            headerTerminator: Self.requestHeaderTerminator,
            maxBytes: Self.maxRequestBytes
        )
        Self.receiveHTTPRequestChunk(on: connection, accumulator: accumulator) { [weak self] content in
            guard let self, self.pendingHTTPRequests[key] != nil else {
                connection.cancel()
                return
            }
            self.processRequest(content, on: connection)
        }
    }

    func finishHTTPRequest(on connection: NWConnection) {
        pendingHTTPRequests.removeValue(forKey: ObjectIdentifier(connection))?.deadlineTask.cancel()
    }

    nonisolated private static func receiveHTTPRequestChunk(
        on connection: NWConnection,
        accumulator: HTTPRequestAccumulator,
        completion: @escaping @MainActor (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { content, _, isComplete, error in
            if let error {
                Task { @MainActor in
                    Self.logConnectionIssue("Receive HTTP request", error: error)
                    completion(nil)
                }
                return
            }

            var nextAccumulator = accumulator
            switch nextAccumulator.ingest(chunk: content, isComplete: isComplete) {
            case .waiting:
                Self.receiveHTTPRequestChunk(on: connection, accumulator: nextAccumulator, completion: completion)
            case .complete(let completedData):
                Task { @MainActor in completion(completedData) }
            case .invalidTooLarge:
                Task { @MainActor in completion(nil) }
            }
        }
    }
}
