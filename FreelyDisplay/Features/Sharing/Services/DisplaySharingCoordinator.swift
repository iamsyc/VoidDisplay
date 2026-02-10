import Foundation
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class DisplaySharingCoordinator {
    private struct DisplayRegistration {
        let displayID: CGDirectDisplayID
        let shareID: UInt32
        let isMain: Bool
    }

    private struct SharingSession {
        let stream: SCStream
        let capture: Capture
        let delegate: StreamDelegate
    }

    private var registrationsByDisplayID: [CGDirectDisplayID: DisplayRegistration] = [:]
    private var displayIDsByShareID: [UInt32: CGDirectDisplayID] = [:]
    private var sessionsByDisplayID: [CGDirectDisplayID: SharingSession] = [:]
    private var mainDisplayID: CGDirectDisplayID?
    private let idStore: DisplayShareIDStore

    init(idStore: DisplayShareIDStore? = nil) {
        self.idStore = idStore ?? DisplayShareIDStore()
    }

    var hasAnyActiveSharing: Bool {
        !sessionsByDisplayID.isEmpty
    }

    var activeSharingDisplayIDs: Set<CGDirectDisplayID> {
        Set(sessionsByDisplayID.keys)
    }

    func registerShareableDisplays(
        _ displays: [SCDisplay],
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) {
        var nextRegistrationsByDisplayID: [CGDirectDisplayID: DisplayRegistration] = [:]
        var nextDisplayIDsByShareID: [UInt32: CGDirectDisplayID] = [:]
        var resolvedMainDisplayID: CGDirectDisplayID?

        for display in displays {
            let displayID = display.displayID
            let isMain = CGDisplayIsMain(displayID) != 0
            if isMain {
                resolvedMainDisplayID = displayID
            }

            let identityKey = makeIdentityKey(
                for: displayID,
                virtualSerialResolver: virtualSerialResolver
            )
            let shareID = idStore.assignID(for: identityKey)
            let registration = DisplayRegistration(
                displayID: displayID,
                shareID: shareID,
                isMain: isMain
            )
            nextRegistrationsByDisplayID[displayID] = registration
            nextDisplayIDsByShareID[shareID] = displayID
        }

        registrationsByDisplayID = nextRegistrationsByDisplayID
        displayIDsByShareID = nextDisplayIDsByShareID
        mainDisplayID = resolvedMainDisplayID ?? mainDisplayID

        let registeredDisplayIDs = Set(nextRegistrationsByDisplayID.keys)
        for displayID in Array(sessionsByDisplayID.keys) where !registeredDisplayIDs.contains(displayID) {
            stopSharing(displayID: displayID)
        }
    }

    func shareID(for displayID: CGDirectDisplayID) -> UInt32? {
        registrationsByDisplayID[displayID]?.shareID
    }

    func displayID(for shareID: UInt32) -> CGDirectDisplayID? {
        displayIDsByShareID[shareID]
    }

    func isSharing(displayID: CGDirectDisplayID) -> Bool {
        sessionsByDisplayID[displayID] != nil
    }

    func startSharing(
        displayID: CGDirectDisplayID,
        stream: SCStream,
        capture: Capture,
        delegate: StreamDelegate
    ) {
        stopSharing(displayID: displayID)
        sessionsByDisplayID[displayID] = SharingSession(
            stream: stream,
            capture: capture,
            delegate: delegate
        )
        if CGDisplayIsMain(displayID) != 0 {
            mainDisplayID = displayID
        }
    }

    func stopSharing(displayID: CGDirectDisplayID) {
        guard let session = sessionsByDisplayID.removeValue(forKey: displayID) else { return }
        session.stream.stopCapture()
        session.capture.resetFrameState()
        _ = session.delegate
    }

    func stopAllSharing() {
        for displayID in Array(sessionsByDisplayID.keys) {
            stopSharing(displayID: displayID)
        }
    }

    func state(for target: ShareTarget) -> ShareTargetState {
        switch target {
        case .main:
            if let resolvedMainID = resolvedMainDisplayID(),
               sessionsByDisplayID[resolvedMainID] != nil {
                return .active
            }
            return .knownInactive
        case .id(let id):
            guard let displayID = displayIDsByShareID[id] else {
                return .unknown
            }
            return sessionsByDisplayID[displayID] != nil ? .active : .knownInactive
        }
    }

    func frame(for target: ShareTarget) -> Data? {
        switch target {
        case .main:
            if let resolvedMainID = resolvedMainDisplayID() {
                return sessionsByDisplayID[resolvedMainID]?.capture.jpgData
            }
            return nil
        case .id(let id):
            guard let displayID = displayIDsByShareID[id] else { return nil }
            return sessionsByDisplayID[displayID]?.capture.jpgData
        }
    }

    func target(for displayID: CGDirectDisplayID) -> ShareTarget? {
        guard let id = registrationsByDisplayID[displayID]?.shareID else { return nil }
        return .id(id)
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

    private func makeIdentityKey(
        for displayID: CGDirectDisplayID,
        virtualSerialResolver: (CGDirectDisplayID) -> UInt32?
    ) -> String {
        if let virtualSerial = virtualSerialResolver(displayID) {
            return "virtual:\(virtualSerial)"
        }

        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let cfUUID = unmanagedUUID.takeRetainedValue()
            let uuidString = CFUUIDCreateString(nil, cfUUID) as String
            return "physical:\(uuidString.lowercased())"
        }
        return "physical-display-id:\(displayID)"
    }
}
