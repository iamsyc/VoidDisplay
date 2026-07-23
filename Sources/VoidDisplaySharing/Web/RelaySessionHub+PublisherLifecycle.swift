import CoreVideo
import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Synchronization

extension RelaySessionHub {
    nonisolated func ensurePublisher(roomID: String) {
        let shouldStart = state.withLock { state -> Bool in
            if state.publisher != nil || state.publisherTask != nil {
                return false
            }
            let profile = state.streamingProfile
            state.publisherGeneration &+= 1
            let generation = state.publisherGeneration
            let task = Task { [weak self, relayClientProvider, publisherFactory] in
                do {
                    let relayClient = try await relayClientProvider()
                    guard let publisher = publisherFactory(roomID, relayClient, profile) else {
                        throw RelaySessionHubError.publisherUnavailable
                    }
                    try await publisher.start()
                    self?.storeStartedPublisher(publisher, roomID: roomID, generation: generation)
                } catch {
                    self?.handlePublisherStartupFailure(error, generation: generation)
                }
            }
            state.publisherTask = task
            return true
        }
        if shouldStart {
            AppLog.web.info("Starting relay publisher for room \(roomID, privacy: .private(mask: .hash)).")
        }
    }

    private nonisolated func storeStartedPublisher(
        _ publisher: any RelayPublisherSessioning,
        roomID: String,
        generation: UInt64
    ) {
        let decision = state.withLock {
            state -> (shouldClose: Bool, profile: WebRTCStreamingProfile?, activeCodecs: Set<WebRTCVideoCodec>) in
            guard state.publisherGeneration == generation else {
                return (true, nil, [])
            }
            state.publisherTask = nil
            guard !state.clients.isEmpty, state.roomID == roomID else {
                return (true, nil, [])
            }
            let profile = state.streamingProfile
            let activeCodecs = Self.activeCodecs(from: state.clients)
            state.publisher = publisher
            return (false, profile, activeCodecs)
        }
        if decision.shouldClose {
            publisher.close()
            return
        }
        if let profile = decision.profile {
            publisher.updateEncodingProfile(profile)
            publisher.updateActiveCodecs(decision.activeCodecs)
        }
        AppLog.web.info("Relay publisher started for room \(roomID, privacy: .private(mask: .hash)).")
    }

    private nonisolated func handlePublisherStartupFailure(_ error: any Error, generation: UInt64) {
        let keys = state.withLock { state -> [ObjectIdentifier] in
            guard state.publisherGeneration == generation else {
                return []
            }
            state.publisherTask = nil
            return Array(state.clients.keys)
        }
        guard !keys.isEmpty else { return }
        AppLog.web.error("Relay publisher startup failed: \(String(describing: error), privacy: .public)")
        for key in keys {
            send(message: SignalingOutboundMessage(type: .error, reason: "relay_publisher_unavailable"), to: key)
            removeClient(for: key, cancelConnection: true)
        }
    }

    nonisolated func waitForPublisherStartup(roomID: String) async -> PublisherStartupWaitResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: publisherStartupWaitTimeout)
        while true {
            let waitResult = state.withLock { state -> PublisherStartupWaitResult? in
                guard state.roomID == roomID else { return .failed }
                if state.publisher != nil {
                    return .ready
                }
                guard state.publisherTask != nil else {
                    return .failed
                }
                return nil
            }
            if let waitResult {
                return waitResult
            }
            if clock.now >= deadline {
                return .timedOut
            }
            if Task.isCancelled {
                return .failed
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return .failed
            }
        }
    }

    nonisolated func isCurrentViewer(
        key: ObjectIdentifier,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64
    ) -> Bool {
        state.withLock { state -> Bool in
            guard let client = state.clients[key] else { return false }
            return client.clientID == clientID
                && client.sessionEpoch == sessionEpoch
                && Self.roomID(for: client.target) == roomID
        }
    }

    nonisolated func stopPublisherIfIdle(force: Bool) {
        let publisher = state.withLock { state -> (any RelayPublisherSessioning)? in
            guard force || state.clients.isEmpty else { return nil }
            state.publisherGeneration &+= 1
            let publisher = state.publisher
            state.publisher = nil
            state.publisherTask?.cancel()
            state.publisherTask = nil
            return publisher
        }
        publisher?.close()
    }
}
