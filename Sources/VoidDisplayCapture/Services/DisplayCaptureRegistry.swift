import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import CoreVideo
import Synchronization
private final class NoopDisplayShareFrameConsumer: DisplayShareFrameConsumer {
    nonisolated var hasDemand: Bool { false }

    package nonisolated func updateSourceVideoSpec(_ spec: SourceVideoSpec) {
        _ = spec
    }

    package nonisolated func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        _ = mode
    }

    package nonisolated func stopSharing() {}

    package nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        _ = pixelBuffer
        _ = ptsUs
    }
}

package actor DisplayCaptureRegistry {
    package enum SessionResourceState: Equatable, Sendable {
        case initializing
        case active
        case draining
        case stopped
    }
    package struct PreviewToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        let displayID: CGDirectDisplayID
    }
    package struct ShareToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        let displayID: CGDirectDisplayID
    }

    private enum RegistryError: Error {
        case sessionUnavailable
    }

    package typealias CaptureSessionFactory = @Sendable (
        SendableDisplay,
        DisplayCaptureProfile,
        CapturePerformanceMode,
        @escaping @Sendable () -> any DisplayShareFrameConsumer
    ) async throws -> any DisplayCaptureSessioning

    private let captureSessionFactory: CaptureSessionFactory
    private let makeShareFrameConsumer: @Sendable () -> any DisplayShareFrameConsumer
    private var performanceMode: CapturePerformanceMode
    private var sessionStore = DisplayCaptureSessionStore()
    private var leaseBook = DisplayCaptureLeaseBook()
    private var sessionEnsureTasksByDisplayID: [
        CGDirectDisplayID: Task<DisplayCaptureSessionStore.Record, Error>
    ] = [:]

    package static let shared = DisplayCaptureRegistry()

    package init(
        performanceMode: CapturePerformanceMode = .automatic,
        makeShareFrameConsumer: @escaping @Sendable () -> any DisplayShareFrameConsumer = { NoopDisplayShareFrameConsumer() },
        captureSessionFactory: @escaping CaptureSessionFactory = { display, initialProfile, initialPerformanceMode, makeShareFrameConsumer in
            try await DisplayCaptureSession(
                display: display.value,
                initialProfile: initialProfile,
                initialPerformanceMode: initialPerformanceMode,
                makeShareFrameConsumer: makeShareFrameConsumer
            )
        }
    ) {
        self.performanceMode = performanceMode
        self.makeShareFrameConsumer = makeShareFrameConsumer
        self.captureSessionFactory = captureSessionFactory
    }

    package func updatePerformanceMode(_ mode: CapturePerformanceMode) async {
        performanceMode = mode
        let displayIDs = sessionStore.activeDisplayIDs
        for displayID in displayIDs {
            try? await applyDemand(for: displayID)
        }
    }

    package func acquirePreview(display: SendableDisplay) async throws -> DisplayPreviewSubscription {
        let token = try await acquirePreviewToken(display: display)
        guard let record = sessionStore.record(for: token.displayID) else {
            throw RegistryError.sessionUnavailable
        }
        return DisplayPreviewSubscription(
            displayID: token.displayID,
            resolutionText: record.resolutionText,
            session: record.session,
            cancelClosure: { Task { await self.release(token) } },
            onAttachedPreviewSinkCountChanged: { [self] delta in
                Task { await self.recordAttachedPreviewSinkDelta(delta, for: token.rawValue) }
            },
            setShowsCursorClosure: { [self] showsCursor in
                try await self.setPreviewShowsCursor(showsCursor, for: token.rawValue)
            }
        )
    }

    package func acquirePreview(
        display: SendableDisplay,
        invalidationContext: DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayPreviewSubscription> {
        try await invalidationContext.race {
            try await self.acquirePreview(display: display)
        }
    }

    package func acquireShare(display: SendableDisplay) async throws -> DisplayShareSubscription {
        let token = try await acquireShareToken(display: display)
        guard let record = sessionStore.record(for: token.displayID) else {
            throw RegistryError.sessionUnavailable
        }
        return DisplayShareSubscription(
            displayID: token.displayID,
            shareFrameConsumer: record.session.shareFrameConsumer,
            cancelClosure: { Task { await self.release(token) } },
            prepareForSharingClosure: { [self] in
                try await self.prepareShareForSharing(token.rawValue)
            },
            releasePreparedShareClosure: { [self] in
                await self.releasePreparedShare(token.rawValue)
            }
        )
    }

    package func acquireShare(
        display: SendableDisplay,
        invalidationContext: DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayShareSubscription> {
        try await invalidationContext.race {
            try await self.acquireShare(display: display)
        }
    }

    package func acquirePreviewToken(display: SendableDisplay) async throws -> PreviewToken {
        let tokenID = try await acquireToken(display: display, kind: .preview)
        return PreviewToken(rawValue: tokenID, displayID: display.displayID)
    }

    package func acquireShareToken(display: SendableDisplay) async throws -> ShareToken {
        let tokenID = try await acquireToken(display: display, kind: .share)
        return ShareToken(rawValue: tokenID, displayID: display.displayID)
    }

    package func release(_ token: PreviewToken) async {
        await releaseToken(token.rawValue, expectedKind: .preview)
    }

    package func release(_ token: ShareToken) async {
        await releaseToken(token.rawValue, expectedKind: .share)
    }

    package func sessionState(for displayID: CGDirectDisplayID) -> SessionResourceState {
        sessionStore.sessionState(for: displayID)
    }

    private func acquireToken(
        display: SendableDisplay,
        kind: DisplayCaptureLeaseBook.TokenKind
    ) async throws -> UUID {
        leaseBook.recordPendingCreationDemand(for: display.displayID, kind: kind, delta: 1)
        do {
            try await ensureSessionExists(for: display, fallbackKind: kind)
            leaseBook.recordPendingCreationDemand(for: display.displayID, kind: kind, delta: -1)
            return try await registerToken(displayID: display.displayID, kind: kind)
        } catch {
            leaseBook.recordPendingCreationDemand(for: display.displayID, kind: kind, delta: -1)
            throw error
        }
    }

#if DEBUG
    package func installSessionForTesting(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning
    ) {
        sessionStore.installSessionForTesting(
            displayID: displayID,
            resolutionText: resolutionText,
            session: session
        )
        configureShareFrameDemand(for: displayID, consumer: session.shareFrameConsumer)
    }

    package func acquirePreviewTokenForTesting(displayID: CGDirectDisplayID) throws -> PreviewToken {
        let tokenID = try registerTokenForTesting(displayID: displayID, kind: .preview)
        return PreviewToken(rawValue: tokenID, displayID: displayID)
    }

    package func acquireShareTokenForTesting(displayID: CGDirectDisplayID) throws -> ShareToken {
        let tokenID = try registerTokenForTesting(displayID: displayID, kind: .share)
        return ShareToken(rawValue: tokenID, displayID: displayID)
    }
#endif

    private func registerToken(
        displayID: CGDirectDisplayID,
        kind: DisplayCaptureLeaseBook.TokenKind
    ) async throws -> UUID {
        guard let record = sessionStore.record(for: displayID) else {
            throw RegistryError.sessionUnavailable
        }
        guard record.state != .draining else {
            throw RegistryError.sessionUnavailable
        }
        let tokenID = leaseBook.registerToken(displayID: displayID, kind: kind)
        if kind == .share {
            _ = leaseBook.setShareFrameDemand(
                record.session.shareFrameConsumer.hasDemand,
                for: displayID
            )
        }
        try? await applyDemand(for: displayID)
        return tokenID
    }

    private func registerTokenForTesting(
        displayID: CGDirectDisplayID,
        kind: DisplayCaptureLeaseBook.TokenKind
    ) throws -> UUID {
        guard let record = sessionStore.record(for: displayID) else {
            throw RegistryError.sessionUnavailable
        }
        guard record.state != .draining else {
            throw RegistryError.sessionUnavailable
        }
        return leaseBook.registerToken(displayID: displayID, kind: kind)
    }

    private func ensureSessionExists(
        for display: SendableDisplay,
        fallbackKind: DisplayCaptureLeaseBook.TokenKind
    ) async throws {
        let displayID = display.displayID
        if let existing = sessionStore.record(for: displayID) {
            if existing.state != .draining {
                return
            }
            if let drainTask = sessionStore.drainTask(for: displayID) {
                await drainTask.value
            }
            if let afterDrain = sessionStore.record(for: displayID), afterDrain.state != .draining {
                return
            }
        }

        if let existingTask = sessionEnsureTasksByDisplayID[display.displayID] {
            let record = try await existingTask.value
            sessionStore.storeInitializedSessionIfAbsent(record, for: displayID)
            return
        }

        let task = Task<DisplayCaptureSessionStore.Record, Error> {
            [self, captureSessionFactory, makeShareFrameConsumer, performanceMode] in
            await Task.yield()
            let initialProfile = await initialProfile(for: displayID, fallbackKind: fallbackKind)
            let session = try await captureSessionFactory(
                display,
                initialProfile,
                performanceMode,
                makeShareFrameConsumer
            )
            return DisplayCaptureSessionStore.Record(
                session: session,
                resolutionText: "\(display.width) × \(display.height)",
                state: .active
            )
        }
        sessionStore.markInitializing(displayID: displayID)
        sessionEnsureTasksByDisplayID[displayID] = task
        defer { sessionEnsureTasksByDisplayID[displayID] = nil }
        do {
            let record = try await task.value
            sessionStore.storeInitializedSessionIfAbsent(record, for: displayID)
            configureShareFrameDemand(for: displayID, consumer: record.session.shareFrameConsumer)
        } catch {
            sessionStore.cancelInitializing(displayID: displayID)
            throw error
        }
    }

    private func releaseToken(
        _ tokenID: UUID,
        expectedKind: DisplayCaptureLeaseBook.TokenKind
    ) async {
        guard let result = leaseBook.releaseToken(tokenID, expectedKind: expectedKind) else {
            return
        }

        guard let record = sessionStore.record(for: result.displayID) else { return }

        if result.shouldStopSharing {
            record.session.stopSharing()
        }
        if result.shouldDrainSession {
            sessionStore.beginDraining(displayID: result.displayID) { [weak self] displayID in
                await self?.finishDrainingSession(displayID: displayID)
            }
        }
        if result.shouldApplyDemand {
            try? await applyDemand(for: result.displayID)
        }
    }

    private func recordAttachedPreviewSinkDelta(_ delta: Int, for tokenID: UUID) async {
        guard let displayID = leaseBook.recordAttachedPreviewSinkDelta(delta, for: tokenID) else {
            return
        }
        try? await applyDemand(for: displayID)
    }

    private func configureShareFrameDemand(
        for displayID: CGDirectDisplayID,
        consumer: any DisplayShareFrameConsumer
    ) {
        let consumerID = ObjectIdentifier(consumer)
        consumer.updateDemandHandler { [weak self] hasDemand in
            guard let self else { return }
            Task {
                await self.recordShareFrameDemand(
                    hasDemand,
                    for: displayID,
                    consumerID: consumerID
                )
            }
        }
    }

    private func recordShareFrameDemand(
        _ hasDemand: Bool,
        for displayID: CGDirectDisplayID,
        consumerID: ObjectIdentifier
    ) async {
        guard let record = sessionStore.record(for: displayID),
              ObjectIdentifier(record.session.shareFrameConsumer) == consumerID,
              record.session.shareFrameConsumer.hasDemand == hasDemand else {
            return
        }
        guard leaseBook.setShareFrameDemand(hasDemand, for: displayID) else { return }
        try? await applyDemand(for: displayID)
    }

    package func recordShareFrameDemandForTesting(
        _ hasDemand: Bool,
        for displayID: CGDirectDisplayID,
        consumer: any DisplayShareFrameConsumer
    ) async {
        await recordShareFrameDemand(
            hasDemand,
            for: displayID,
            consumerID: ObjectIdentifier(consumer)
        )
    }

    private func setPreviewShowsCursor(_ showsCursor: Bool, for tokenID: UUID) async throws {
        guard let mutation = leaseBook.setPreviewShowsCursor(showsCursor, for: tokenID) else {
            return
        }

        do {
            try await applyDemand(for: mutation.displayID)
        } catch {
            leaseBook.revertPreviewShowsCursor(for: tokenID, previousValue: mutation.previousValue)
            try? await applyDemand(for: mutation.displayID)
            throw error
        }
    }

    private func prepareShareForSharing(_ tokenID: UUID) async throws {
        guard let displayID = leaseBook.prepareShareForSharing(tokenID) else { return }

        do {
            try await applyDemand(for: displayID)
        } catch {
            leaseBook.revertPreparedShare(tokenID)
            try? await applyDemand(for: displayID)
            throw error
        }
    }

    private func releasePreparedShare(_ tokenID: UUID) async {
        guard let displayID = leaseBook.releasePreparedShare(tokenID) else { return }
        try? await applyDemand(for: displayID)
    }

    private func applyDemand(for displayID: CGDirectDisplayID) async throws {
        guard let record = sessionStore.record(for: displayID), record.state != .draining else {
            return
        }
        var demand = leaseBook.demandSnapshot(for: displayID, performanceMode: performanceMode)
        while true {
            try await record.session.setDemand(demand)
            guard let currentRecord = sessionStore.record(for: displayID),
                  currentRecord.state != .draining,
                  ObjectIdentifier(currentRecord.session) == ObjectIdentifier(record.session)
            else {
                return
            }
            let latestDemand = leaseBook.demandSnapshot(
                for: displayID,
                performanceMode: performanceMode
            )
            guard latestDemand != demand else { return }
            demand = latestDemand
        }
    }

    private func finishDrainingSession(displayID: CGDirectDisplayID) {
        sessionStore.finishDraining(displayID: displayID)
    }

    private func initialProfile(
        for displayID: CGDirectDisplayID,
        fallbackKind: DisplayCaptureLeaseBook.TokenKind
    ) async -> DisplayCaptureProfile {
        leaseBook.initialProfile(for: displayID, fallbackKind: fallbackKind)
    }
}
