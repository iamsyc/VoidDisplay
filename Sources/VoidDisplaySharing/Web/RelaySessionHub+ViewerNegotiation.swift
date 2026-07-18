import Foundation
import VoidDisplayFoundation
import VoidDisplayObservability

extension RelaySessionHub {
    nonisolated func storeOfferTask(
        _ task: Task<Void, Never>,
        key: ObjectIdentifier,
        clientID: String,
        sessionEpoch: UInt64
    ) {
        let stored = state.withLock { state -> Bool in
            guard var client = state.clients[key],
                  client.clientID == clientID,
                  client.sessionEpoch == sessionEpoch,
                  client.negotiationPhase == .offerInFlight else {
                return false
            }
            client.offerTask = task
            state.clients[key] = client
            return true
        }
        if !stored {
            task.cancel()
        }
    }

    private nonisolated func clearOfferTask(
        key: ObjectIdentifier,
        clientID: String,
        sessionEpoch: UInt64
    ) {
        state.withLock { state in
            guard var client = state.clients[key],
                  client.clientID == clientID,
                  client.sessionEpoch == sessionEpoch else {
                return
            }
            client.offerTask = nil
            state.clients[key] = client
        }
    }

    private nonisolated func resetOfferForRetry(
        key: ObjectIdentifier,
        clientID: String,
        sessionEpoch: UInt64
    ) {
        state.withLock { state in
            guard var client = state.clients[key],
                  client.clientID == clientID,
                  client.sessionEpoch == sessionEpoch else {
                return
            }
            client.negotiationPhase = .awaitingOffer
            client.pendingViewerCandidates.removeAll(keepingCapacity: true)
            client.isCandidateDrainRunning = false
            client.candidateDrainTask?.cancel()
            client.candidateDrainTask = nil
            state.clients[key] = client
        }
    }

    nonisolated func rejectInboundSignal(reason: String, to key: ObjectIdentifier) {
        AppLog.web.warning("Rejecting inbound signaling message: \(reason, privacy: .public)")
        enqueue(
            message: SignalingOutboundMessage(type: .error, reason: reason),
            to: key,
            disconnectAfterSend: true,
            replacePending: true
        )
    }

    nonisolated func launchCandidateDrain(
        key: ObjectIdentifier,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainViewerCandidates(
                key: key,
                roomID: roomID,
                clientID: clientID,
                sessionEpoch: sessionEpoch
            )
        }
        let stored = state.withLock { state -> Bool in
            guard var client = state.clients[key],
                  client.clientID == clientID,
                  client.sessionEpoch == sessionEpoch,
                  client.negotiationPhase == .established,
                  client.isCandidateDrainRunning else {
                return false
            }
            client.candidateDrainTask = task
            state.clients[key] = client
            return true
        }
        if !stored {
            task.cancel()
        }
    }

    private nonisolated func drainViewerCandidates(
        key: ObjectIdentifier,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64
    ) async {
        var permitsRestart = true
        defer {
            if finishCandidateDrain(
                key: key,
                roomID: roomID,
                clientID: clientID,
                sessionEpoch: sessionEpoch,
                permitsRestart: permitsRestart
            ) {
                launchCandidateDrain(
                    key: key,
                    roomID: roomID,
                    clientID: clientID,
                    sessionEpoch: sessionEpoch
                )
            }
        }

        do {
            let relayClient = try await relayClientProvider()
            while !Task.isCancelled {
                guard let candidate = takeNextViewerCandidate(
                    key: key,
                    roomID: roomID,
                    clientID: clientID,
                    sessionEpoch: sessionEpoch
                ) else {
                    return
                }
                try await relayClient.viewerCandidate(
                    roomID: roomID,
                    clientID: clientID,
                    candidate: candidate.candidate,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: candidate.sdpMLineIndex
                )
                guard isCurrentViewer(
                    key: key,
                    roomID: roomID,
                    clientID: clientID,
                    sessionEpoch: sessionEpoch
                ) else {
                    permitsRestart = false
                    await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                    return
                }
            }
        } catch {
            permitsRestart = false
            if isCurrentViewer(
                key: key,
                roomID: roomID,
                clientID: clientID,
                sessionEpoch: sessionEpoch
            ) {
                AppLog.web.warning("Relay viewer ICE candidate failed: \(String(describing: error), privacy: .public)")
                rejectInboundSignal(reason: "relay_viewer_candidate_failed", to: key)
            }
        }
    }

    private nonisolated func takeNextViewerCandidate(
        key: ObjectIdentifier,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64
    ) -> PendingViewerCandidate? {
        state.withLock { state -> PendingViewerCandidate? in
            guard var client = state.clients[key],
                  client.clientID == clientID,
                  client.sessionEpoch == sessionEpoch,
                  Self.roomID(for: client.target) == roomID,
                  client.negotiationPhase == .established,
                  !client.pendingViewerCandidates.isEmpty else {
                return nil
            }
            let candidate = client.pendingViewerCandidates.removeFirst()
            state.clients[key] = client
            return candidate
        }
    }

    private nonisolated func finishCandidateDrain(
        key: ObjectIdentifier,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64,
        permitsRestart: Bool
    ) -> Bool {
        state.withLock { state -> Bool in
            guard var client = state.clients[key],
                  client.clientID == clientID,
                  client.sessionEpoch == sessionEpoch,
                  Self.roomID(for: client.target) == roomID else {
                return false
            }
            client.candidateDrainTask = nil
            client.isCandidateDrainRunning = false
            guard permitsRestart,
                  client.negotiationPhase == .established,
                  !client.pendingViewerCandidates.isEmpty else {
                if !permitsRestart {
                    client.pendingViewerCandidates.removeAll(keepingCapacity: false)
                }
                state.clients[key] = client
                return false
            }
            client.isCandidateDrainRunning = true
            state.clients[key] = client
            return true
        }
    }

    nonisolated func forwardViewerOffer(
        sdp: String,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64,
        key: ObjectIdentifier
    ) async {
        defer {
            clearOfferTask(key: key, clientID: clientID, sessionEpoch: sessionEpoch)
        }
        do {
            try Task.checkCancellation()
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                return
            }
            ensurePublisher(roomID: roomID)
            switch await waitForPublisherStartup(roomID: roomID) {
            case .ready:
                break
            case .timedOut:
                guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                    return
                }
                resetOfferForRetry(key: key, clientID: clientID, sessionEpoch: sessionEpoch)
                enqueue(
                    message: SignalingOutboundMessage(type: .codecPending, reason: "publisher_codec_pending"),
                    to: key,
                    disconnectAfterSend: false,
                    replacePending: true
                )
                return
            case .failed:
                guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                    return
                }
                enqueue(
                    message: SignalingOutboundMessage(type: .error, reason: "relay_publisher_unavailable"),
                    to: key,
                    disconnectAfterSend: true,
                    replacePending: true
                )
                return
            }
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                return
            }
            let relayClient = try await relayClientProvider()
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                return
            }
            let answer = try await relayClient.viewerOffer(roomID: roomID, clientID: clientID, sdp: sdp)
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                return
            }
            let update = state.withLock {
                state -> (
                    publisher: (any RelayPublisherSessioning)?,
                    activeCodecs: Set<WebRTCVideoCodec>,
                    sourceVideoSpec: SourceVideoSpec,
                    shouldStartCandidateDrain: Bool
                )? in
                guard var client = state.clients[key],
                      client.clientID == clientID,
                      client.sessionEpoch == sessionEpoch,
                      Self.roomID(for: client.target) == roomID,
                      client.negotiationPhase == .offerInFlight else {
                    return nil
                }
                client.selectedCodec = answer.codec
                client.negotiationPhase = .established
                let shouldStartCandidateDrain = !client.pendingViewerCandidates.isEmpty
                    && !client.isCandidateDrainRunning
                if shouldStartCandidateDrain {
                    client.isCandidateDrainRunning = true
                }
                state.clients[key] = client
                return (
                    state.publisher,
                    Self.activeCodecs(from: state.clients),
                    state.sourceVideoSpec,
                    shouldStartCandidateDrain
                )
            }
            guard let update else {
                await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                return
            }
            update.publisher?.updateActiveCodecs(update.activeCodecs)
            send(
                message: SignalingOutboundMessage(
                    type: .answer,
                    sdp: answer.sdp,
                    sourceVideoSpec: SourceVideoSpecSignalPayload(spec: update.sourceVideoSpec)
                ),
                to: key
            )
            if update.shouldStartCandidateDrain {
                launchCandidateDrain(
                    key: key,
                    roomID: roomID,
                    clientID: clientID,
                    sessionEpoch: sessionEpoch
                )
            }
            emitEvent(phase: .peerConnected, source: .peerConnection, for: key)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                return
            }
            AppLog.web.warning("Relay viewer offer failed: \(String(describing: error), privacy: .public)")
            let relayReason = (error as? RelayHTTPError)?.relayReason
            if relayReason == "publisher_codec_pending" {
                resetOfferForRetry(key: key, clientID: clientID, sessionEpoch: sessionEpoch)
                enqueue(
                    message: SignalingOutboundMessage(type: .codecPending, reason: "publisher_codec_pending"),
                    to: key,
                    disconnectAfterSend: false,
                    replacePending: true
                )
                return
            }
            let message: SignalingOutboundMessage
            if relayReason == "unsupported_video_codec_offered" || relayReason == "supported_video_codec_missing" {
                message = SignalingOutboundMessage(type: .error, reason: relayReason)
            } else {
                message = SignalingOutboundMessage(type: .error, reason: "relay_viewer_offer_failed")
            }
            enqueue(message: message, to: key, disconnectAfterSend: true, replacePending: true)
        }
    }
}
