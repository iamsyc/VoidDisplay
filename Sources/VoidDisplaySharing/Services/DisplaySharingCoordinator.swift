import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
package final class DisplaySharingCoordinator {
    package typealias AcquireShare = @MainActor (
        SCDisplay,
        DisplayStartInvalidationContext
    ) async throws -> DisplayStartOutcome<DisplayShareSubscription>
    package struct ShareableDisplayRegistrationInput {
        let displayID: CGDirectDisplayID
        let isMain: Bool
        let virtualSerial: UInt32?

        package init(displayID: CGDirectDisplayID, isMain: Bool, virtualSerial: UInt32?) {
            self.displayID = displayID
            self.isMain = isMain
            self.virtualSerial = virtualSerial
        }
    }

    private struct DisplayRegistration {
        let displayID: CGDirectDisplayID
        let shareID: UInt32
        let isMain: Bool
    }

    private struct SharingSession {
        let display: SCDisplay
        let subscription: DisplayShareSubscription
        let accessCapability: ShareAccessCapability
    }

    private var registrationsByDisplayID: [CGDirectDisplayID: DisplayRegistration] = [:]
    private var displayIDsByShareID: [UInt32: CGDirectDisplayID] = [:]
    private var sessionsByDisplayID: [CGDirectDisplayID: SharingSession] = [:]
    private var mainDisplayID: CGDirectDisplayID?
    private let idStore: DisplayShareIDStore
    private let startCoordinator: DisplayStreamStartCoordinator
    private let acquireShare: AcquireShare
    private let accessCapabilityGenerator: @MainActor () throws -> ShareAccessCapability

    package init(
        idStore: DisplayShareIDStore,
        startCoordinator: DisplayStreamStartCoordinator = DisplayStreamStartCoordinator(),
        acquireShare: @escaping AcquireShare = { _, _ in throw CancellationError() },
        accessCapabilityGenerator: @escaping @MainActor () throws -> ShareAccessCapability = ShareAccessCapability.generate
    ) {
        self.idStore = idStore
        self.startCoordinator = startCoordinator
        self.acquireShare = acquireShare
        self.accessCapabilityGenerator = accessCapabilityGenerator
    }

    package var hasAnyActiveSharing: Bool {
        !sessionsByDisplayID.isEmpty
    }

    package var activeSharingDisplayIDs: Set<CGDirectDisplayID> {
        Set(sessionsByDisplayID.keys)
    }

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        startCoordinator.isStarting(kind: .sharing, displayID: displayID)
    }

    @discardableResult
    package func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) -> Set<ShareTarget> {
        let inputs = displays.map { display in
            ShareableDisplayRegistrationInput(
                displayID: display.displayID,
                isMain: CGDisplayIsMain(display.displayID) != 0,
                virtualSerial: virtualSerialResolver(display.displayID)
            )
        }
        return registerShareableDisplays(inputs)
    }

    @discardableResult
    package func registerShareableDisplays(_ inputs: [ShareableDisplayRegistrationInput]) -> Set<ShareTarget> {
        var nextRegistrationsByDisplayID: [CGDirectDisplayID: DisplayRegistration] = [:]
        var nextDisplayIDsByShareID: [UInt32: CGDirectDisplayID] = [:]
        var resolvedMainDisplayID: CGDirectDisplayID?
        var reservedShareIDs = Set<UInt32>()

        let virtualInputs = inputs
            .filter { $0.virtualSerial != nil }
            .sorted {
                let lhsSerial = $0.virtualSerial ?? 0
                let rhsSerial = $1.virtualSerial ?? 0
                if lhsSerial != rhsSerial { return lhsSerial < rhsSerial }
                return $0.displayID < $1.displayID
            }
        for (index, input) in virtualInputs.enumerated() {
            let shareID = input.virtualSerial ?? UInt32(index + 1)
            reservedShareIDs.insert(shareID)
            if input.isMain {
                resolvedMainDisplayID = input.displayID
            }
            let registration = DisplayRegistration(
                displayID: input.displayID,
                shareID: shareID,
                isMain: input.isMain
            )
            nextRegistrationsByDisplayID[input.displayID] = registration
            nextDisplayIDsByShareID[shareID] = input.displayID
        }

        let physicalInputs = inputs
            .filter { $0.virtualSerial == nil }
            .sorted { $0.displayID < $1.displayID }
        for input in physicalInputs {
            if input.isMain, resolvedMainDisplayID == nil {
                resolvedMainDisplayID = input.displayID
            }
            let identityKey = makeIdentityKey(for: input.displayID)
            let shareID = idStore.assignID(for: identityKey, excluding: reservedShareIDs)
            reservedShareIDs.insert(shareID)
            let registration = DisplayRegistration(
                displayID: input.displayID,
                shareID: shareID,
                isMain: input.isMain
            )
            nextRegistrationsByDisplayID[input.displayID] = registration
            nextDisplayIDsByShareID[shareID] = input.displayID
        }

        let currentRegistrationsByDisplayID = registrationsByDisplayID
        let invalidatedTargets = invalidatedConcreteTargets(
            current: currentRegistrationsByDisplayID,
            next: nextRegistrationsByDisplayID
        )
        let displayIDsToInvalidate = invalidatedDisplayIDs(
            current: currentRegistrationsByDisplayID,
            next: nextRegistrationsByDisplayID
        )
        registrationsByDisplayID = nextRegistrationsByDisplayID
        displayIDsByShareID = nextDisplayIDsByShareID
        mainDisplayID = resolvedMainDisplayID ?? mainDisplayID
        for displayID in displayIDsToInvalidate {
            startCoordinator.invalidate(kind: .sharing, displayID: displayID)
        }

        let registeredDisplayIDs = Set(nextRegistrationsByDisplayID.keys)
        for displayID in Array(sessionsByDisplayID.keys) where !registeredDisplayIDs.contains(displayID) {
            stopSharing(displayID: displayID)
        }
        return invalidatedTargets
    }

    package func startSharing(display: SCDisplay) async throws -> DisplayStartOutcome<Void> {
        let displayID = display.displayID
        guard registrationsByDisplayID[displayID] != nil else {
            throw SharingStartError.displayNotRegistered(displayID)
        }

        return try await startCoordinator.start(
            kind: .sharing,
            displayID: displayID
        ) { [self, acquireShare] invalidationContext in
            guard self.registrationsByDisplayID[displayID] != nil else {
                return .invalidated
            }
            self.stopActiveSharingSession(displayID: displayID)

            let subscription: DisplayShareSubscription
            switch try await acquireShare(display, invalidationContext) {
            case .invalidated:
                return .invalidated
            case .started(let acquiredSubscription):
                subscription = acquiredSubscription
            }

            if invalidationContext.isInvalidated() || self.registrationsByDisplayID[displayID] == nil {
                subscription.cancel()
                return .invalidated
            }

            switch try await subscription.prepareForSharing(invalidationContext: invalidationContext) {
            case .invalidated:
                return .invalidated
            case .started:
                break
            }

            if invalidationContext.isInvalidated() || self.registrationsByDisplayID[displayID] == nil {
                subscription.cancel()
                return .invalidated
            }
            let accessCapability: ShareAccessCapability
            do {
                accessCapability = try self.accessCapabilityGenerator()
            } catch {
                subscription.cancel()
                throw error
            }
            self.sessionsByDisplayID[displayID] = SharingSession(
                display: display,
                subscription: subscription,
                accessCapability: accessCapability
            )
            if CGDisplayIsMain(displayID) != 0 {
                self.mainDisplayID = displayID
            }
            return .started(())
        }
    }

    package func stopSharing(displayID: CGDirectDisplayID) {
        startCoordinator.invalidate(kind: .sharing, displayID: displayID)
        stopActiveSharingSession(displayID: displayID)
    }

    private func stopActiveSharingSession(displayID: CGDirectDisplayID) {
        guard let session = sessionsByDisplayID.removeValue(forKey: displayID) else { return }
        session.subscription.cancel()
    }

    package func stopAllSharing() {
        startCoordinator.invalidateAll(kind: .sharing)
        for displayID in Array(sessionsByDisplayID.keys) {
            stopActiveSharingSession(displayID: displayID)
        }
    }

    package func authorize(
        target: ShareTarget,
        capability: ShareAccessCapability
    ) -> AuthorizedShareSession? {
        let shareID: UInt32
        let displayID: CGDirectDisplayID
        switch target {
        case .main:
            guard let resolvedMainID = resolvedMainDisplayID(),
                  let resolvedShareID = registrationsByDisplayID[resolvedMainID]?.shareID else {
                return nil
            }
            shareID = resolvedShareID
            displayID = resolvedMainID
        case .id(let id):
            guard let resolvedDisplayID = displayIDsByShareID[id] else { return nil }
            shareID = id
            displayID = resolvedDisplayID
        }

        guard let session = sessionsByDisplayID[displayID],
              session.accessCapability.securelyMatches(capability),
              let hub = session.subscription.shareFrameConsumer as? any SignalSessionHub else {
            return nil
        }
        return AuthorizedShareSession(id: shareID, sessionHub: hub)
    }

    package func shareID(for displayID: CGDirectDisplayID) -> UInt32? {
        registrationsByDisplayID[displayID]?.shareID
    }

    package func target(for displayID: CGDirectDisplayID) -> ShareTarget? {
        guard let id = registrationsByDisplayID[displayID]?.shareID else { return nil }
        return .id(id)
    }

    package func sharePagePath(for displayID: CGDirectDisplayID) -> String? {
        guard let target = target(for: displayID),
              let capability = sessionsByDisplayID[displayID]?.accessCapability else {
            return nil
        }
        return target.displayPath(accessCapability: capability)
    }

    package func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sessionsByDisplayID[displayID] != nil
    }

    private func resolvedMainDisplayID() -> CGDirectDisplayID? {
        if let mainDisplayID,
           registrationsByDisplayID[mainDisplayID] != nil || sessionsByDisplayID[mainDisplayID] != nil {
            return mainDisplayID
        }

        if let registeredMain = registrationsByDisplayID.values.first(where: { $0.isMain })?.displayID {
            mainDisplayID = registeredMain
            return registeredMain
        }

        let systemMain = CGMainDisplayID()
        if registrationsByDisplayID[systemMain] != nil || sessionsByDisplayID[systemMain] != nil {
            mainDisplayID = systemMain
            return systemMain
        }
        return nil
    }

    private func invalidatedDisplayIDs(
        current: [CGDirectDisplayID: DisplayRegistration],
        next: [CGDirectDisplayID: DisplayRegistration]
    ) -> Set<CGDirectDisplayID> {
        let allDisplayIDs = Set(current.keys).union(next.keys)
        return Set(
            allDisplayIDs.filter { displayID in
                switch (current[displayID], next[displayID]) {
                case (.none, .some), (.some, .none):
                    true
                case (.some(let old), .some(let new)):
                    old.shareID != new.shareID || old.isMain != new.isMain
                case (.none, .none):
                    false
                }
            }
        )
    }

    private func invalidatedConcreteTargets(
        current: [CGDirectDisplayID: DisplayRegistration],
        next: [CGDirectDisplayID: DisplayRegistration]
    ) -> Set<ShareTarget> {
        Set(
            current.compactMap { displayID, registration in
                switch next[displayID] {
                case .none:
                    return .id(registration.shareID)
                case .some(let nextRegistration):
                    guard registration.shareID != nextRegistration.shareID else {
                        return nil
                    }
                    return .id(registration.shareID)
                }
            }
        )
    }

    private func makeIdentityKey(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            let uuidString = CFUUIDCreateString(nil, cfUUID) as String
            return "physical:\(uuidString.lowercased())"
        }
        return "physical-display-id:\(displayID)"
    }
}
