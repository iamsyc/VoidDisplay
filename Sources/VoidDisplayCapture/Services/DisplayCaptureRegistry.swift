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
    private var isShuttingDown = false
    private nonisolated let sessionTerminationHandler = Mutex<(@MainActor @Sendable (CGDirectDisplayID) -> Void)?>(nil)
    private var sessionEnsureTasksByDisplayID: [
        CGDirectDisplayID: Task<Void, Error>
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

    package nonisolated func setSessionTerminationHandler(
        _ handler: @escaping @MainActor @Sendable (CGDirectDisplayID) -> Void
    ) {
        sessionTerminationHandler.withLock { $0 = handler }
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

    package func shutdown() async {
        isShuttingDown = true
        let creationTasks = Array(sessionEnsureTasksByDisplayID.values)
        for task in creationTasks { task.cancel() }
        for displayID in sessionStore.activeDisplayIDs {
            leaseBook.invalidateTokens(for: displayID)
            sessionStore.beginDraining(displayID: displayID) { [weak self] displayID in
                await self?.finishDrainingSession(displayID: displayID)
            }
        }
        let drainTasks = sessionStore.drainTasks
        for task in creationTasks { _ = await task.result }
        for task in drainTasks { await task.value }
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
        configureSessionTermination(for: displayID, session: session)
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

        guard !isShuttingDown else { throw RegistryError.sessionUnavailable }
        if let existingTask = sessionEnsureTasksByDisplayID[displayID] {
            try await existingTask.value
            return
        }

        let task = Task<Void, Error> {
            [self, captureSessionFactory, makeShareFrameConsumer, performanceMode] in
            defer {
                sessionEnsureTasksByDisplayID[displayID] = nil
                sessionStore.cancelInitializing(displayID: displayID)
            }
            await Task.yield()
            try Task.checkCancellation()
            let initialProfile = leaseBook.initialProfile(for: displayID, fallbackKind: fallbackKind)
            let session = try await captureSessionFactory(
                display,
                initialProfile,
                performanceMode,
                makeShareFrameConsumer
            )
            guard !isShuttingDown else {
                await session.stop()
                throw RegistryError.sessionUnavailable
            }
            let record = DisplayCaptureSessionStore.Record(
                session: session,
                resolutionText: "\(display.width) × \(display.height)",
                state: .active
            )
            sessionStore.storeInitializedSessionIfAbsent(record, for: displayID)
            configureSessionTermination(for: displayID, session: record.session)
            configureShareFrameDemand(for: displayID, consumer: record.session.shareFrameConsumer)
        }
        sessionStore.markInitializing(displayID: displayID)
        sessionEnsureTasksByDisplayID[displayID] = task
        try await task.value
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

    private func configureSessionTermination(
        for displayID: CGDirectDisplayID,
        session: any DisplayCaptureSessioning
    ) {
        let sessionID = ObjectIdentifier(session)
        session.setTerminationHandler { [weak self] in
            Task { await self?.sessionDidTerminate(displayID: displayID, sessionID: sessionID) }
        }
    }

    private func sessionDidTerminate(displayID: CGDirectDisplayID, sessionID: ObjectIdentifier) {
        guard let record = sessionStore.record(for: displayID),
              record.state != .draining,
              ObjectIdentifier(record.session) == sessionID else { return }
        leaseBook.invalidateTokens(for: displayID)
        let handler = sessionTerminationHandler.withLock { $0 }
        sessionStore.beginDraining(
            displayID: displayID,
            beforeStop: { await handler?(displayID) },
            onStopCompleted: { [weak self] displayID in
                await self?.finishDrainingSession(displayID: displayID)
            }
        )
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
            do {
                try await record.session.setDemand(demand)
            } catch {
                if !(error is CancellationError) {
                    sessionDidTerminate(displayID: displayID, sessionID: ObjectIdentifier(record.session))
                    await MainActor.run {
                        AppErrorMapper.logFailure(
                            "Apply screen capture demand", error: error, logger: AppLog.capture, subsystem: .capture
                        )
                    }
                }
                throw error
            }
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

}
