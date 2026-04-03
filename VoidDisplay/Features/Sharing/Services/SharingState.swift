import Foundation

enum SharingSessionEventSource: String, Sendable, Equatable, Codable {
    case webSocket
    case peerConnection
}

enum SharingPeerPhase: String, Sendable, Equatable, Codable {
    case signalingConnected
    case offerReceived
    case peerConnected
    case peerDisconnected
    case peerFailed
    case closed
}

struct SharingSessionEvent: Sendable, Equatable {
    let target: ShareTarget
    let clientID: String
    let sequence: UInt64
    let phase: SharingPeerPhase
    let source: SharingSessionEventSource
    let timestamp: Date

    nonisolated var recordedPhase: SharingPeerPhase {
        phase
    }

    nonisolated var recordedSequence: UInt64 {
        sequence
    }

    nonisolated init(
        target: ShareTarget,
        clientID: String,
        sequence: UInt64 = 0,
        phase: SharingPeerPhase,
        source: SharingSessionEventSource,
        timestamp: Date = Date()
    ) {
        self.target = target
        self.clientID = clientID
        self.sequence = sequence
        self.phase = phase
        self.source = source
        self.timestamp = timestamp
    }
}

struct SharingClientState: Sendable, Equatable {
    let target: ShareTarget
    let clientID: String
    let phase: SharingPeerPhase
    let source: SharingSessionEventSource
    let lastUpdatedAt: Date

    nonisolated var recordedPhase: SharingPeerPhase {
        phase
    }

    nonisolated init(
        target: ShareTarget,
        clientID: String,
        phase: SharingPeerPhase,
        source: SharingSessionEventSource,
        lastUpdatedAt: Date
    ) {
        self.target = target
        self.clientID = clientID
        self.phase = phase
        self.source = source
        self.lastUpdatedAt = lastUpdatedAt
    }

    var hasActiveSignalingConnection: Bool {
        phase != .closed
    }

    var hasActiveStreamingPeer: Bool {
        phase == .peerConnected
    }
}

struct SharingStateSnapshot: Sendable, Equatable {
    let signalingConnections: Int
    let streamingPeers: Int
    let signalingConnectionsByTarget: [ShareTarget: Int]
    let streamingPeersByTarget: [ShareTarget: Int]
    let clientsByTarget: [ShareTarget: [String: SharingClientState]]
    let lastUpdatedAt: Date?

    static let empty = SharingStateSnapshot(
        signalingConnections: 0,
        streamingPeers: 0,
        signalingConnectionsByTarget: [:],
        streamingPeersByTarget: [:],
        clientsByTarget: [:],
        lastUpdatedAt: nil
    )
}

@MainActor
final class SharingStateSubscription {
    private let cancelClosure: @MainActor () -> Void
    private var isCancelled = false

    init(cancelClosure: @escaping @MainActor () -> Void) {
        self.cancelClosure = cancelClosure
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelClosure()
    }
}

@MainActor
final class SharingStateAggregator {
    typealias Observer = @MainActor @Sendable (SharingStateSnapshot) -> Void
    nonisolated static let closedClientTombstoneLimit = 512

    private var clientStatesByID: [String: SharingClientState] = [:]
    private var lastAcceptedSequenceByClientID: [String: UInt64] = [:]
    private var closedClientTombstoneSequenceByClientID: [String: UInt64] = [:]
    private var closedClientTombstoneOrder: [(clientID: String, sequence: UInt64)] = []
    private var observers: [UUID: Observer] = [:]
    private var snapshot = SharingStateSnapshot.empty

    var currentSnapshot: SharingStateSnapshot {
        snapshot
    }

    var closedClientTombstoneCountForTesting: Int {
        closedClientTombstoneSequenceByClientID.count
    }

    func record(_ event: SharingSessionEvent) {
        if let lastAcceptedSequence = lastAcceptedSequenceByClientID[event.clientID],
           event.sequence <= lastAcceptedSequence {
            return
        }
        if let closedClientSequence = closedClientTombstoneSequenceByClientID[event.clientID] {
            guard event.sequence > closedClientSequence else { return }
            closedClientTombstoneSequenceByClientID.removeValue(forKey: event.clientID)
        }
        if event.phase == .closed {
            clientStatesByID.removeValue(forKey: event.clientID)
            lastAcceptedSequenceByClientID.removeValue(forKey: event.clientID)
            closedClientTombstoneSequenceByClientID[event.clientID] = event.sequence
            closedClientTombstoneOrder.append((event.clientID, event.sequence))
            pruneClosedClientTombstonesIfNeeded()
        } else {
            lastAcceptedSequenceByClientID[event.clientID] = event.sequence
            let nextState = SharingClientState(
                target: event.target,
                clientID: event.clientID,
                phase: event.phase,
                source: event.source,
                lastUpdatedAt: event.timestamp
            )
            clientStatesByID[event.clientID] = nextState
        }
        rebuildSnapshot(lastUpdatedAt: event.timestamp)
    }

    func reset() {
        clientStatesByID.removeAll()
        lastAcceptedSequenceByClientID.removeAll()
        closedClientTombstoneSequenceByClientID.removeAll()
        closedClientTombstoneOrder.removeAll()
        rebuildSnapshot(lastUpdatedAt: nil)
    }

    func subscribe(_ observer: @escaping Observer) -> SharingStateSubscription {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return SharingStateSubscription { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    private func rebuildSnapshot(lastUpdatedAt: Date?) {
        var clientsByTarget: [ShareTarget: [String: SharingClientState]] = [:]
        var signalingConnectionsByTarget: [ShareTarget: Int] = [:]
        var streamingPeersByTarget: [ShareTarget: Int] = [:]

        for clientState in clientStatesByID.values {
            clientsByTarget[clientState.target, default: [:]][clientState.clientID] = clientState
            if clientState.hasActiveSignalingConnection {
                signalingConnectionsByTarget[clientState.target, default: 0] += 1
            }
            if clientState.hasActiveStreamingPeer {
                streamingPeersByTarget[clientState.target, default: 0] += 1
            }
        }

        let signalingConnections = signalingConnectionsByTarget.values.reduce(0, +)
        let streamingPeers = streamingPeersByTarget.values.reduce(0, +)
        snapshot = SharingStateSnapshot(
            signalingConnections: signalingConnections,
            streamingPeers: streamingPeers,
            signalingConnectionsByTarget: signalingConnectionsByTarget,
            streamingPeersByTarget: streamingPeersByTarget,
            clientsByTarget: clientsByTarget,
            lastUpdatedAt: lastUpdatedAt
        )

        for observer in observers.values {
            observer(snapshot)
        }
    }

    private func pruneClosedClientTombstonesIfNeeded() {
        while closedClientTombstoneSequenceByClientID.count > Self.closedClientTombstoneLimit,
              let oldest = closedClientTombstoneOrder.first {
            closedClientTombstoneOrder.removeFirst()
            guard closedClientTombstoneSequenceByClientID[oldest.clientID] == oldest.sequence else { continue }
            closedClientTombstoneSequenceByClientID.removeValue(forKey: oldest.clientID)
        }
    }
}
