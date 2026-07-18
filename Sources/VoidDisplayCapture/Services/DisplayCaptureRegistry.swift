import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import CoreVideo
import Synchronization
package final class DisplayPreviewSubscription: Sendable {
    package let displayID: CGDirectDisplayID
    package let resolutionText: String

    private let session: any DisplayCaptureSessioning
    private let onAttachedPreviewSinkCountChanged: @Sendable (Int) -> Void
    private let setShowsCursorClosure: @Sendable (Bool) async throws -> Void
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)
    private let attachedSinks = Mutex<[ObjectIdentifier: WeakSink]>([:])

    private final class WeakSink: @unchecked Sendable {
        nonisolated(unsafe) weak var value: (any DisplayPreviewSink)?

        nonisolated init(_ value: any DisplayPreviewSink) {
            self.value = value
        }
    }

    package nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning,
        cancelClosure: @escaping @Sendable () -> Void,
        onAttachedPreviewSinkCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
        setShowsCursorClosure: @escaping @Sendable (Bool) async throws -> Void = { _ in }
    ) {
        self.displayID = displayID
        self.resolutionText = resolutionText
        self.session = session
        self.onAttachedPreviewSinkCountChanged = onAttachedPreviewSinkCountChanged
        self.setShowsCursorClosure = setShowsCursorClosure
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        let shouldAttach = attachedSinks.withLock { attachedSinks -> Bool in
            let key = ObjectIdentifier(sink as AnyObject)
            if let existing = attachedSinks[key], existing.value != nil {
                return false
            }
            attachedSinks[key] = WeakSink(sink)
            return true
        }
        guard shouldAttach else { return }
        session.attachPreviewSink(sink)
        onAttachedPreviewSinkCountChanged(1)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        let shouldDetach = attachedSinks.withLock { attachedSinks -> Bool in
            let key = ObjectIdentifier(sink as AnyObject)
            guard let removed = attachedSinks.removeValue(forKey: key) else {
                return false
            }
            return removed.value != nil
        }
        guard shouldDetach else { return }
        session.detachPreviewSink(sink)
        onAttachedPreviewSinkCountChanged(-1)
    }

    nonisolated func cancel() {
        let session = self.session
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        guard let closure else { return }

        let sinksToDetach: [any DisplayPreviewSink] = attachedSinks.withLock { dict in
            let snapshot = dict.values.compactMap(\.value)
            dict.removeAll(keepingCapacity: true)
            return snapshot
        }
        for sink in sinksToDetach {
            session.detachPreviewSink(sink)
            onAttachedPreviewSinkCountChanged(-1)
        }

        closure()
    }

    package nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot {
        session.captureMetricsSnapshot()
    }

    nonisolated func setShowsCursor(_ showsCursor: Bool) async throws {
        try await setShowsCursorClosure(showsCursor)
    }

    deinit { cancel() }
}
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
package struct DisplayCaptureSessionStore {
    package struct Record: Sendable {
        let session: any DisplayCaptureSessioning
        let resolutionText: String
        var state: DisplayCaptureRegistry.SessionResourceState
    }

    private var recordsByDisplayID: [CGDirectDisplayID: Record] = [:]
    private var sessionDrainTasksByDisplayID: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var initializingDisplayIDs: Set<CGDirectDisplayID> = []

    package var activeDisplayIDs: [CGDirectDisplayID] {
        recordsByDisplayID.compactMap { displayID, record in
            record.state == .draining ? nil : displayID
        }
    }

    package func record(for displayID: CGDirectDisplayID) -> Record? {
        recordsByDisplayID[displayID]
    }

    package func sessionState(
        for displayID: CGDirectDisplayID
    ) -> DisplayCaptureRegistry.SessionResourceState {
        if initializingDisplayIDs.contains(displayID) {
            return .initializing
        }
        return recordsByDisplayID[displayID]?.state ?? .stopped
    }

    package mutating func installSessionForTesting(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning
    ) {
        sessionDrainTasksByDisplayID[displayID]?.cancel()
        sessionDrainTasksByDisplayID[displayID] = nil
        initializingDisplayIDs.remove(displayID)
        recordsByDisplayID[displayID] = Record(
            session: session,
            resolutionText: resolutionText,
            state: .active
        )
    }

    package mutating func markActive(displayID: CGDirectDisplayID) {
        guard var record = recordsByDisplayID[displayID] else { return }
        record.state = .active
        recordsByDisplayID[displayID] = record
    }

    package mutating func markInitializing(displayID: CGDirectDisplayID) {
        initializingDisplayIDs.insert(displayID)
    }

    package mutating func cancelInitializing(displayID: CGDirectDisplayID) {
        initializingDisplayIDs.remove(displayID)
    }

    package mutating func storeInitializedSessionIfAbsent(
        _ record: Record,
        for displayID: CGDirectDisplayID
    ) {
        initializingDisplayIDs.remove(displayID)
        guard recordsByDisplayID[displayID] == nil else { return }
        recordsByDisplayID[displayID] = record
    }

    package func drainTask(for displayID: CGDirectDisplayID) -> Task<Void, Never>? {
        sessionDrainTasksByDisplayID[displayID]
    }

    package mutating func beginDraining(
        displayID: CGDirectDisplayID,
        onStopCompleted: @escaping @Sendable (CGDirectDisplayID) async -> Void
    ) {
        guard var record = recordsByDisplayID[displayID] else { return }
        record.state = .draining
        recordsByDisplayID[displayID] = record

        let session = record.session
        sessionDrainTasksByDisplayID[displayID]?.cancel()
        sessionDrainTasksByDisplayID[displayID] = Task { [displayID] in
            await session.stop()
            await onStopCompleted(displayID)
        }
    }

    package mutating func finishDraining(displayID: CGDirectDisplayID, hasActiveTokens: Bool) {
        sessionDrainTasksByDisplayID[displayID] = nil
        guard let record = recordsByDisplayID[displayID] else { return }
        guard record.state == .draining else { return }

        if hasActiveTokens {
            var resumedRecord = record
            resumedRecord.state = .active
            recordsByDisplayID[displayID] = resumedRecord
            return
        }

        recordsByDisplayID.removeValue(forKey: displayID)
    }
}
package struct DisplayCaptureLeaseBook {
    package enum TokenKind: Sendable {
        case preview
        case share
    }
    package struct PreviewLeaseState: Sendable, Equatable {
        var attachedSinkCount = 0
        var showsCursor = false
    }
    package struct ReleaseResult: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let shouldStopSharing: Bool
        let shouldApplyDemand: Bool
        let shouldDrainSession: Bool
    }
    package struct PreviewCursorMutation: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let previousValue: Bool
    }

    private struct TokenRecord: Sendable {
        let kind: TokenKind
        let displayID: CGDirectDisplayID
    }

    private struct PendingCreationDemand: Sendable {
        var previewCount = 0
        var shareCount = 0

        mutating func record(_ kind: TokenKind, delta: Int) {
            switch kind {
            case .preview:
                previewCount = max(0, previewCount + delta)
            case .share:
                shareCount = max(0, shareCount + delta)
            }
        }

        var initialProfile: DisplayCaptureProfile? {
            DisplayCaptureDemandSnapshot(
                attachedPreviewSinkCount: previewCount,
                shareTokenCount: shareCount,
                performanceMode: .automatic
            ).desiredProfile
        }

        var isEmpty: Bool {
            previewCount == 0 && shareCount == 0
        }
    }

    private struct DisplayState {
        var previewTokens: [UUID: PreviewLeaseState] = [:]
        var shareTokens: Set<UUID> = []
        var shareCursorOverrideTokens: Set<UUID> = []
        var hasShareFrameDemand = false

        var hasActiveTokens: Bool {
            previewTokens.isEmpty == false || shareTokens.isEmpty == false
        }
    }

    private var statesByDisplayID: [CGDirectDisplayID: DisplayState] = [:]
    private var tokenOwnership: [UUID: TokenRecord] = [:]
    private var pendingCreationDemandByDisplayID: [CGDirectDisplayID: PendingCreationDemand] = [:]

    mutating func recordPendingCreationDemand(
        for displayID: CGDirectDisplayID,
        kind: TokenKind,
        delta: Int
    ) {
        var demand = pendingCreationDemandByDisplayID[displayID] ?? PendingCreationDemand()
        demand.record(kind, delta: delta)
        if demand.isEmpty {
            pendingCreationDemandByDisplayID.removeValue(forKey: displayID)
        } else {
            pendingCreationDemandByDisplayID[displayID] = demand
        }
    }

    func initialProfile(
        for displayID: CGDirectDisplayID,
        fallbackKind: TokenKind
    ) -> DisplayCaptureProfile {
        if let profile = pendingCreationDemandByDisplayID[displayID]?.initialProfile {
            return profile
        }

        switch fallbackKind {
        case .preview:
            return .previewOnly
        case .share:
            return .shareOnly
        }
    }

    mutating func registerToken(displayID: CGDirectDisplayID, kind: TokenKind) -> UUID {
        let tokenID = UUID()
        var state = statesByDisplayID[displayID] ?? DisplayState()
        switch kind {
        case .preview:
            state.previewTokens[tokenID] = PreviewLeaseState()
        case .share:
            state.shareTokens.insert(tokenID)
        }
        statesByDisplayID[displayID] = state
        tokenOwnership[tokenID] = TokenRecord(kind: kind, displayID: displayID)
        return tokenID
    }

    mutating func releaseToken(_ tokenID: UUID, expectedKind: TokenKind) -> ReleaseResult? {
        guard let ownership = tokenOwnership.removeValue(forKey: tokenID),
              ownership.kind == expectedKind else {
            return nil
        }

        var state = statesByDisplayID[ownership.displayID] ?? DisplayState()
        switch ownership.kind {
        case .preview:
            state.previewTokens.removeValue(forKey: tokenID)
        case .share:
            state.shareTokens.remove(tokenID)
            if state.shareTokens.isEmpty {
                state.hasShareFrameDemand = false
            }
        }
        state.shareCursorOverrideTokens.remove(tokenID)

        let shouldDrainSession = state.hasActiveTokens == false
        let shouldStopSharing = ownership.kind == .share && state.shareTokens.isEmpty
        let shouldApplyDemand = shouldDrainSession == false

        if state.previewTokens.isEmpty && state.shareTokens.isEmpty && state.shareCursorOverrideTokens.isEmpty {
            statesByDisplayID.removeValue(forKey: ownership.displayID)
        } else {
            statesByDisplayID[ownership.displayID] = state
        }

        return ReleaseResult(
            displayID: ownership.displayID,
            shouldStopSharing: shouldStopSharing,
            shouldApplyDemand: shouldApplyDemand,
            shouldDrainSession: shouldDrainSession
        )
    }

    mutating func recordAttachedPreviewSinkDelta(_ delta: Int, for tokenID: UUID) -> CGDirectDisplayID? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .preview,
              var state = statesByDisplayID[ownership.displayID],
              var lease = state.previewTokens[tokenID] else {
            return nil
        }
        lease.attachedSinkCount = max(0, lease.attachedSinkCount + delta)
        state.previewTokens[tokenID] = lease
        statesByDisplayID[ownership.displayID] = state
        return ownership.displayID
    }

    mutating func setShareFrameDemand(
        _ hasDemand: Bool,
        for displayID: CGDirectDisplayID
    ) -> Bool {
        guard var state = statesByDisplayID[displayID] else { return false }
        let effectiveDemand = hasDemand && !state.shareTokens.isEmpty
        guard state.hasShareFrameDemand != effectiveDemand else { return false }
        state.hasShareFrameDemand = effectiveDemand
        statesByDisplayID[displayID] = state
        return true
    }

    mutating func setPreviewShowsCursor(
        _ showsCursor: Bool,
        for tokenID: UUID
    ) -> PreviewCursorMutation? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .preview,
              var state = statesByDisplayID[ownership.displayID],
              var lease = state.previewTokens[tokenID] else {
            return nil
        }
        let previousValue = lease.showsCursor
        guard previousValue != showsCursor else { return nil }

        lease.showsCursor = showsCursor
        state.previewTokens[tokenID] = lease
        statesByDisplayID[ownership.displayID] = state
        return PreviewCursorMutation(displayID: ownership.displayID, previousValue: previousValue)
    }

    mutating func revertPreviewShowsCursor(for tokenID: UUID, previousValue: Bool) {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .preview,
              var state = statesByDisplayID[ownership.displayID],
              var lease = state.previewTokens[tokenID] else {
            return
        }
        lease.showsCursor = previousValue
        state.previewTokens[tokenID] = lease
        statesByDisplayID[ownership.displayID] = state
    }

    mutating func prepareShareForSharing(_ tokenID: UUID) -> CGDirectDisplayID? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .share,
              var state = statesByDisplayID[ownership.displayID] else {
            return nil
        }
        guard state.shareCursorOverrideTokens.contains(tokenID) == false else { return nil }

        state.shareCursorOverrideTokens.insert(tokenID)
        statesByDisplayID[ownership.displayID] = state
        return ownership.displayID
    }

    mutating func revertPreparedShare(_ tokenID: UUID) {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .share,
              var state = statesByDisplayID[ownership.displayID] else {
            return
        }
        guard state.shareCursorOverrideTokens.remove(tokenID) != nil else { return }
        statesByDisplayID[ownership.displayID] = state
    }

    mutating func releasePreparedShare(_ tokenID: UUID) -> CGDirectDisplayID? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .share,
              var state = statesByDisplayID[ownership.displayID] else {
            return nil
        }
        guard state.shareCursorOverrideTokens.remove(tokenID) != nil else { return nil }
        statesByDisplayID[ownership.displayID] = state
        return ownership.displayID
    }

    func demandSnapshot(
        for displayID: CGDirectDisplayID,
        performanceMode: CapturePerformanceMode
    ) -> DisplayCaptureDemandSnapshot {
        let state = statesByDisplayID[displayID] ?? DisplayState()
        return DisplayCaptureDemandSnapshot(
            attachedPreviewSinkCount: state.previewTokens.values.reduce(0) { partialResult, lease in
                partialResult + lease.attachedSinkCount
            },
            shareTokenCount: state.hasShareFrameDemand ? state.shareTokens.count : 0,
            previewShowsCursor: state.previewTokens.values.contains { $0.showsCursor },
            shareCursorOverrideCount: state.shareCursorOverrideTokens.count,
            performanceMode: performanceMode
        )
    }

    func hasActiveTokens(for displayID: CGDirectDisplayID) -> Bool {
        statesByDisplayID[displayID]?.hasActiveTokens == true
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
        sessionStore.markActive(displayID: displayID)
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
        sessionStore.markActive(displayID: displayID)
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
        sessionStore.finishDraining(
            displayID: displayID,
            hasActiveTokens: leaseBook.hasActiveTokens(for: displayID)
        )
    }

    private func initialProfile(
        for displayID: CGDirectDisplayID,
        fallbackKind: DisplayCaptureLeaseBook.TokenKind
    ) async -> DisplayCaptureProfile {
        leaseBook.initialProfile(for: displayID, fallbackKind: fallbackKind)
    }
}
