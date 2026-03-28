import CoreGraphics
import Foundation
import Synchronization

final class DisplayPreviewSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let resolutionText: String

    private let session: any DisplayCaptureSessioning
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)
    private let attachedSinks = Mutex<[ObjectIdentifier: WeakSink]>([:])

    private final class WeakSink: @unchecked Sendable {
        nonisolated(unsafe) weak var value: (any DisplayPreviewSink)?

        nonisolated init(_ value: any DisplayPreviewSink) {
            self.value = value
        }
    }

    nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning,
        cancelClosure: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.resolutionText = resolutionText
        self.session = session
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
        }

        closure()
    }

    nonisolated func setShowsCursor(_ showsCursor: Bool) async throws {
        try await session.setPreviewShowsCursor(showsCursor)
    }

    deinit { cancel() }
}

final class DisplayShareSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let sessionHub: WebRTCSessionHub

    private let session: any DisplayCaptureSessioning
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)
    private let prepareRetainTask = Mutex<Task<Void, Error>?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        sessionHub: WebRTCSessionHub,
        session: any DisplayCaptureSessioning,
        cancelClosure: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.sessionHub = sessionHub
        self.session = session
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func prepareForSharing() async throws {
        try await session.retainShareCursorOverride()
    }

    nonisolated func prepareForSharing(
        invalidationContext: DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<Void> {
        let retainTask = Task {
            try await session.retainShareCursorOverride()
        }
        prepareRetainTask.withLock { state in
            state = retainTask
        }
        do {
            let outcome = try await invalidationContext.race {
                try await retainTask.value
            }
            switch outcome {
            case .started:
                prepareRetainTask.withLock { state in
                    state = nil
                }
            case .invalidated:
                cancel()
            }
            return outcome
        } catch {
            cancel()
            throw error
        }
    }

    nonisolated func cancel() {
        let session = self.session
        let pendingRetainTask = prepareRetainTask.withLock { state -> Task<Void, Error>? in
            let current = state
            state = nil
            return current
        }
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        guard let closure else { return }
        if let pendingRetainTask {
            Task.detached {
                do {
                    try await pendingRetainTask.value
                } catch {
                }
                try? await session.releaseShareCursorOverride()
                closure()
            }
            return
        }
        Task {
            try? await session.releaseShareCursorOverride()
            closure()
        }
    }

    deinit { cancel() }
}

actor DisplayCaptureRegistry {
    enum SessionResourceState: Equatable {
        case initializing
        case active
        case draining
        case stopped
    }

    struct PreviewToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        let displayID: CGDirectDisplayID
    }

    struct ShareToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
        let displayID: CGDirectDisplayID
    }

    private enum TokenKind: Sendable {
        case preview
        case share
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
            DisplayCaptureProfileStateMachine.desiredProfile(
                previewSinkCount: previewCount,
                sharingActive: shareCount > 0
            )
        }

        var isEmpty: Bool {
            previewCount == 0 && shareCount == 0
        }
    }

    struct SessionRecord {
        let session: any DisplayCaptureSessioning
        let resolutionText: String
        var state: SessionResourceState
        var previewTokens: Set<UUID>
        var shareTokens: Set<UUID>
    }

    private enum RegistryError: Error {
        case sessionUnavailable
    }

    private struct ReleaseSideEffects {
        let session: any DisplayCaptureSessioning
        let setSharingActiveTo: Bool?
        let stopSharing: Bool
    }

    typealias CaptureSessionFactory = @Sendable (
        SendableDisplay,
        DisplayCaptureProfile
    ) async throws -> any DisplayCaptureSessioning

    static let shared = DisplayCaptureRegistry()

    private let captureSessionFactory: CaptureSessionFactory
    private var sessionsByDisplayID: [CGDirectDisplayID: SessionRecord] = [:]
    private var tokenOwnership: [UUID: TokenRecord] = [:]
    private var sessionCreationTasks: [CGDirectDisplayID: Task<SessionRecord, Error>] = [:]
    private var pendingCreationDemandByDisplayID: [CGDirectDisplayID: PendingCreationDemand] = [:]
    private var sessionDrainTasksByDisplayID: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var initializingDisplayIDs: Set<CGDirectDisplayID> = []

    init(
        captureSessionFactory: @escaping CaptureSessionFactory = { display, initialProfile in
            try await DisplayCaptureSession(display: display.value, initialProfile: initialProfile)
        }
    ) {
        self.captureSessionFactory = captureSessionFactory
    }

    func acquirePreview(display: SendableDisplay) async throws -> DisplayPreviewSubscription {
        let token = try await acquirePreviewToken(display: display)
        guard let record = sessionsByDisplayID[token.displayID] else {
            throw RegistryError.sessionUnavailable
        }
        return DisplayPreviewSubscription(
            displayID: token.displayID,
            resolutionText: record.resolutionText,
            session: record.session,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.release(token) }
            }
        )
    }

    func acquirePreview(
        display: SendableDisplay,
        invalidationContext: DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayPreviewSubscription> {
        try await invalidationContext.race {
            try await self.acquirePreview(display: display)
        }
    }

    func acquireShare(display: SendableDisplay) async throws -> DisplayShareSubscription {
        let token = try await acquireShareToken(display: display)
        guard let record = sessionsByDisplayID[token.displayID] else {
            throw RegistryError.sessionUnavailable
        }
        return DisplayShareSubscription(
            displayID: token.displayID,
            sessionHub: record.session.sessionHub,
            session: record.session,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.release(token) }
            }
        )
    }

    func acquireShare(
        display: SendableDisplay,
        invalidationContext: DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayShareSubscription> {
        try await invalidationContext.race {
            try await self.acquireShare(display: display)
        }
    }

    func acquirePreviewToken(display: SendableDisplay) async throws -> PreviewToken {
        let tokenID = try await acquireToken(display: display, kind: .preview)
        return PreviewToken(rawValue: tokenID, displayID: display.displayID)
    }

    func acquireShareToken(display: SendableDisplay) async throws -> ShareToken {
        let tokenID = try await acquireToken(display: display, kind: .share)
        return ShareToken(rawValue: tokenID, displayID: display.displayID)
    }

    func release(_ token: PreviewToken) async {
        await releaseToken(token.rawValue, expectedKind: .preview)
    }

    func release(_ token: ShareToken) async {
        await releaseToken(token.rawValue, expectedKind: .share)
    }

    func sessionState(for displayID: CGDirectDisplayID) -> SessionResourceState {
        if initializingDisplayIDs.contains(displayID) {
            return .initializing
        }
        return sessionsByDisplayID[displayID]?.state ?? .stopped
    }

    private func acquireToken(
        display: SendableDisplay,
        kind: TokenKind
    ) async throws -> UUID {
        recordPendingCreationDemand(for: display.displayID, kind: kind, delta: 1)
        do {
            try await ensureSessionExists(for: display, fallbackKind: kind)
            recordPendingCreationDemand(for: display.displayID, kind: kind, delta: -1)
            return try await registerToken(displayID: display.displayID, kind: kind)
        } catch {
            recordPendingCreationDemand(for: display.displayID, kind: kind, delta: -1)
            throw error
        }
    }

#if DEBUG
    func installSessionForTesting(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: any DisplayCaptureSessioning
    ) {
        sessionDrainTasksByDisplayID[displayID]?.cancel()
        sessionDrainTasksByDisplayID[displayID] = nil
        initializingDisplayIDs.remove(displayID)
        sessionsByDisplayID[displayID] = SessionRecord(
            session: session,
            resolutionText: resolutionText,
            state: .active,
            previewTokens: [],
            shareTokens: []
        )
    }

    func acquirePreviewTokenForTesting(displayID: CGDirectDisplayID) throws -> PreviewToken {
        let tokenID = try registerTokenForTesting(displayID: displayID, kind: .preview)
        return PreviewToken(rawValue: tokenID, displayID: displayID)
    }

    func acquireShareTokenForTesting(displayID: CGDirectDisplayID) throws -> ShareToken {
        let tokenID = try registerTokenForTesting(displayID: displayID, kind: .share)
        return ShareToken(rawValue: tokenID, displayID: displayID)
    }
#endif

    private func registerToken(displayID: CGDirectDisplayID, kind: TokenKind) async throws -> UUID {
        let tokenID = UUID()
        guard var record = sessionsByDisplayID[displayID] else {
            throw RegistryError.sessionUnavailable
        }
        guard record.state != .draining else {
            throw RegistryError.sessionUnavailable
        }
        record.state = .active
        switch kind {
        case .preview:
            record.previewTokens.insert(tokenID)
        case .share:
            record.shareTokens.insert(tokenID)
        }
        sessionsByDisplayID[displayID] = record
        tokenOwnership[tokenID] = TokenRecord(kind: kind, displayID: displayID)
        try? await record.session.setSharingActive(!record.shareTokens.isEmpty)
        return tokenID
    }

    private func registerTokenForTesting(displayID: CGDirectDisplayID, kind: TokenKind) throws -> UUID {
        let tokenID = UUID()
        guard var record = sessionsByDisplayID[displayID] else {
            throw RegistryError.sessionUnavailable
        }
        guard record.state != .draining else {
            throw RegistryError.sessionUnavailable
        }
        record.state = .active
        switch kind {
        case .preview:
            record.previewTokens.insert(tokenID)
        case .share:
            record.shareTokens.insert(tokenID)
        }
        sessionsByDisplayID[displayID] = record
        tokenOwnership[tokenID] = TokenRecord(kind: kind, displayID: displayID)
        return tokenID
    }

    private func ensureSessionExists(
        for display: SendableDisplay,
        fallbackKind: TokenKind
    ) async throws {
        let displayID = display.displayID
        if let existing = sessionsByDisplayID[displayID] {
            if existing.state != .draining {
                return
            }
            await waitForDrainCompletion(for: displayID)
            if let afterDrain = sessionsByDisplayID[displayID], afterDrain.state != .draining {
                return
            }
        }

        if let existingTask = sessionCreationTasks[displayID] {
            let record = try await existingTask.value
            storeInitializedSessionIfAbsent(record, for: displayID)
            return
        }

        let task = Task<SessionRecord, Error> { [captureSessionFactory] in
            let initialProfile = await self.resolveInitialProfileForPendingCreation(
                displayID: displayID,
                fallbackKind: fallbackKind
            )
            let session = try await captureSessionFactory(display, initialProfile)
            return SessionRecord(
                session: session,
                resolutionText: "\(display.width) × \(display.height)",
                state: .active,
                previewTokens: [],
                shareTokens: []
            )
        }
        initializingDisplayIDs.insert(displayID)
        sessionCreationTasks[displayID] = task
        defer { sessionCreationTasks[displayID] = nil }

        do {
            let record = try await task.value
            storeInitializedSessionIfAbsent(record, for: displayID)
        } catch {
            initializingDisplayIDs.remove(displayID)
            throw error
        }
    }

    private func storeInitializedSessionIfAbsent(
        _ record: SessionRecord,
        for displayID: CGDirectDisplayID
    ) {
        initializingDisplayIDs.remove(displayID)
        guard sessionsByDisplayID[displayID] == nil else { return }
        sessionsByDisplayID[displayID] = record
    }

    private func releaseToken(_ tokenID: UUID, expectedKind: TokenKind) async {
        let sideEffects: ReleaseSideEffects
        guard let ownership = tokenOwnership.removeValue(forKey: tokenID),
              ownership.kind == expectedKind else {
            return
        }
        guard var record = sessionsByDisplayID[ownership.displayID] else { return }

        switch ownership.kind {
        case .preview:
            record.previewTokens.remove(tokenID)
        case .share:
            record.shareTokens.remove(tokenID)
        }

        if record.previewTokens.isEmpty, record.shareTokens.isEmpty {
            record.state = .draining
            sessionsByDisplayID[ownership.displayID] = record
            let session = record.session
            sessionDrainTasksByDisplayID[ownership.displayID]?.cancel()
            sessionDrainTasksByDisplayID[ownership.displayID] = Task { [session] in
                await session.stop()
                self.finishDrainingSession(displayID: ownership.displayID)
            }
            sideEffects = ReleaseSideEffects(
                session: session,
                setSharingActiveTo: nil,
                stopSharing: ownership.kind == .share
            )
        } else {
            record.state = .active
            sessionsByDisplayID[ownership.displayID] = record
            sideEffects = ReleaseSideEffects(
                session: record.session,
                setSharingActiveTo: !record.shareTokens.isEmpty,
                stopSharing: ownership.kind == .share && record.shareTokens.isEmpty
            )
        }

        if sideEffects.stopSharing {
            sideEffects.session.stopSharing()
        }
        if let isSharingActive = sideEffects.setSharingActiveTo {
            try? await sideEffects.session.setSharingActive(isSharingActive)
        }
    }

    private func waitForDrainCompletion(for displayID: CGDirectDisplayID) async {
        guard let drainTask = sessionDrainTasksByDisplayID[displayID] else { return }
        await drainTask.value
    }

    private func finishDrainingSession(displayID: CGDirectDisplayID) {
        sessionDrainTasksByDisplayID[displayID] = nil
        guard let record = sessionsByDisplayID[displayID] else { return }
        guard record.state == .draining else { return }
        guard record.previewTokens.isEmpty, record.shareTokens.isEmpty else {
            var resumed = record
            resumed.state = .active
            sessionsByDisplayID[displayID] = resumed
            return
        }
        sessionsByDisplayID.removeValue(forKey: displayID)
    }

    private func recordPendingCreationDemand(
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

    private func resolveInitialProfileForPendingCreation(
        displayID: CGDirectDisplayID,
        fallbackKind: TokenKind
    ) async -> DisplayCaptureProfile {
        await Task.yield()
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
}
