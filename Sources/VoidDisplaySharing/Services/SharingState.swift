import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package enum SharingSessionEventSource: String, Sendable, Equatable, Codable {
    case webSocket
    case peerConnection
}
package enum SharingPeerPhase: String, Sendable, Equatable, Codable {
    case signalingConnected
    case offerReceived
    case peerConnected
    case peerDisconnected
    case peerFailed
    case closed
}
package struct SharingSessionEvent: Sendable, Equatable {
    package let target: ShareTarget
    package let clientID: String
    package let sessionEpoch: UInt64
    package let sequence: UInt64
    package let phase: SharingPeerPhase
    package let source: SharingSessionEventSource
    package let timestamp: Date

    nonisolated var recordedPhase: SharingPeerPhase {
        phase
    }

    nonisolated var recordedSequence: UInt64 {
        sequence
    }

    nonisolated var recordedSessionEpoch: UInt64 {
        sessionEpoch
    }

    nonisolated init(
        target: ShareTarget,
        clientID: String,
        sessionEpoch: UInt64 = 0,
        sequence: UInt64 = 0,
        phase: SharingPeerPhase,
        source: SharingSessionEventSource,
        timestamp: Date = Date()
    ) {
        self.target = target
        self.clientID = clientID
        self.sessionEpoch = sessionEpoch
        self.sequence = sequence
        self.phase = phase
        self.source = source
        self.timestamp = timestamp
    }
}
package struct SharingClientState: Sendable, Equatable {
    package let target: ShareTarget
    package let clientID: String
    package let phase: SharingPeerPhase
    package let source: SharingSessionEventSource
    package let lastUpdatedAt: Date

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

    package var hasActiveSignalingConnection: Bool {
        phase != .closed
    }

    package var hasActiveStreamingPeer: Bool {
        phase == .peerConnected
    }
}
package struct SharingStateSnapshot: Sendable, Equatable {
    package let signalingConnections: Int
    package let streamingPeers: Int
    package let signalingConnectionsByTarget: [ShareTarget: Int]
    package let streamingPeersByTarget: [ShareTarget: Int]
    package let clientsByTarget: [ShareTarget: [String: SharingClientState]]
    package let lastUpdatedAt: Date?

    package static let empty = SharingStateSnapshot(
        signalingConnections: 0,
        streamingPeers: 0,
        signalingConnectionsByTarget: [:],
        streamingPeersByTarget: [:],
        clientsByTarget: [:],
        lastUpdatedAt: nil
    )
}

@MainActor
package final class SharingStateSubscription {
    private let cancelClosure: @MainActor () -> Void
    private var isCancelled = false

    package init(cancelClosure: @escaping @MainActor () -> Void) {
        self.cancelClosure = cancelClosure
    }

    package func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelClosure()
    }
}

@MainActor
package final class SharingStateAggregator {
    package typealias Observer = @MainActor @Sendable (SharingStateSnapshot) -> Void
    nonisolated static let closedClientTombstoneLimit = 512

    private struct ConnectionKey: Hashable {
        let clientID: String
        let sessionEpoch: UInt64
    }

    private var clientStatesByConnectionKey: [ConnectionKey: SharingClientState] = [:]
    private var lastAcceptedSequenceByConnectionKey: [ConnectionKey: UInt64] = [:]
    private var closedClientTombstoneSequenceByConnectionKey: [ConnectionKey: UInt64] = [:]
    private var closedClientTombstoneOrder: [(key: ConnectionKey, sequence: UInt64)] = []
    private var observers: [UUID: Observer] = [:]
    private var snapshot = SharingStateSnapshot.empty

    package var currentSnapshot: SharingStateSnapshot {
        snapshot
    }

    package var closedClientTombstoneCountForTesting: Int {
        closedClientTombstoneSequenceByConnectionKey.count
    }

    package func record(_ event: SharingSessionEvent) {
        let key = ConnectionKey(clientID: event.clientID, sessionEpoch: event.sessionEpoch)
        if let lastAcceptedSequence = lastAcceptedSequenceByConnectionKey[key],
           event.sequence <= lastAcceptedSequence {
            return
        }
        if closedClientTombstoneSequenceByConnectionKey[key] != nil {
            return
        }
        if event.phase == .closed {
            clientStatesByConnectionKey.removeValue(forKey: key)
            lastAcceptedSequenceByConnectionKey.removeValue(forKey: key)
            closedClientTombstoneSequenceByConnectionKey[key] = event.sequence
            closedClientTombstoneOrder.append((key, event.sequence))
            pruneClosedClientTombstonesIfNeeded()
        } else {
            lastAcceptedSequenceByConnectionKey[key] = event.sequence
            let nextState = SharingClientState(
                target: event.target,
                clientID: event.clientID,
                phase: event.phase,
                source: event.source,
                lastUpdatedAt: event.timestamp
            )
            clientStatesByConnectionKey[key] = nextState
        }
        rebuildSnapshot(lastUpdatedAt: event.timestamp)
    }

    package func reset() {
        clientStatesByConnectionKey.removeAll()
        lastAcceptedSequenceByConnectionKey.removeAll()
        closedClientTombstoneSequenceByConnectionKey.removeAll()
        closedClientTombstoneOrder.removeAll()
        rebuildSnapshot(lastUpdatedAt: nil)
    }

    package func subscribe(_ observer: @escaping Observer) -> SharingStateSubscription {
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

        for clientState in clientStatesByConnectionKey.values {
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
        while closedClientTombstoneSequenceByConnectionKey.count > Self.closedClientTombstoneLimit,
              let oldest = closedClientTombstoneOrder.first {
            closedClientTombstoneOrder.removeFirst()
            guard closedClientTombstoneSequenceByConnectionKey[oldest.key] == oldest.sequence else { continue }
            closedClientTombstoneSequenceByConnectionKey.removeValue(forKey: oldest.key)
        }
    }
}
