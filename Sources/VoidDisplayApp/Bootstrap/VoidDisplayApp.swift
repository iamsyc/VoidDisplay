import VoidDisplayVirtualDisplay
import VoidDisplayCGVirtualDisplay
import VoidDisplayCapture
import VoidDisplayDesignSystem
import VoidDisplaySharing
import VoidDisplaySupport
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplayFoundation
//
//  VoidDisplayApp.swift
//  VoidDisplay
//
//

import AppKit
import Darwin
import Foundation
import SwiftUI

public struct VoidDisplayApplication: App {
    @NSApplicationDelegateAdaptor(VoidDisplayApplicationDelegate.self) private var appDelegate
    @State private var capture: CaptureController
    @State private var sharing: SharingController
    @State private var virtualDisplay: VirtualDisplayController
    @State private var capturePerformancePreferences: CapturePerformancePreferences
    @State private var navigation: AppNavigationController
    @State private var feedbackController: AppSettingsFeedbackController
    private let observability: ObservabilityCenter
    private let displayRuntime: DisplayRuntime
    private let sharingAdapter: DisplayRuntimeSharingAdapter
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    public init() {
        AppSingleInstanceGuard.acquireSingleInstanceLockOrExit()
        let env = AppBootstrap.makeEnvironment()
        _capture = State(initialValue: env.capture)
        _sharing = State(initialValue: env.sharing)
        _virtualDisplay = State(initialValue: env.virtualDisplay)
        _capturePerformancePreferences = State(initialValue: env.capturePerformancePreferences)
        _navigation = State(initialValue: AppNavigationController())
        _feedbackController = State(initialValue: env.feedbackController)
        observability = env.observability
        displayRuntime = env.displayRuntime
        sharingAdapter = env.sharingAdapter
        openScreenCapturePrivacySettings = env.openScreenCapturePrivacySettings
        AppTerminationCleanup.install {
            env.sharing.stopWebService()
        }
    }

    public var body: some Scene {
        WindowGroup {
            Group {
                if UITestRuntime.isEnabled && UITestRuntime.scenario == .settingsFeedback {
                    AppSettingsView(
                        observability: observability,
                        feedbackController: feedbackController
                    )
                } else if UITestRuntime.isEnabled && UITestRuntime.scenario == .previewRecovery {
                    PreviewRecoveryUITestHost()
                } else if UITestRuntime.isEnabled && UITestRuntime.scenario == .previewWindowPayload {
                    CaptureDisplayWindowRoot(
                        previewID: nil,
                        previewActions: CaptureUIComposition.previewActions(
                            capture: capture,
                            displayRuntime: displayRuntime,
                            capturePerformancePreferences: capturePerformancePreferences
                        ),
                        sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing)
                    )
                } else {
                    HomeView(
                        observability: observability,
                        feedbackController: feedbackController,
                        displayRuntime: displayRuntime,
                        sharingAdapter: sharingAdapter,
                        openScreenCapturePrivacySettings: openScreenCapturePrivacySettings
                    )
                }
            }
            .environment(capture)
            .environment(sharing)
            .environment(virtualDisplay)
            .environment(capturePerformancePreferences)
            .environment(navigation)
            .overlay {
                if UITestRuntime.shouldAdvanceFocus {
                    UITestFocusTraversalHost()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(
            width: UITestRuntime.windowSize?.width ?? 1180,
            height: UITestRuntime.windowSize?.height ?? 720
        )

        WindowGroup(for: CapturePreviewID.self) { $previewID in
            CaptureDisplayWindowRoot(
                previewID: previewID,
                previewActions: CaptureUIComposition.previewActions(
                    capture: capture,
                    displayRuntime: displayRuntime,
                    capturePerformancePreferences: capturePerformancePreferences
                ),
                sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing)
            )
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            AppSettingsView(
                observability: observability,
                feedbackController: feedbackController
            )
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
                .environment(capturePerformancePreferences)
                .environment(navigation)
        }
    }
}

private struct UITestFocusTraversalHost: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        UITestFocusTraversalView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class UITestFocusTraversalView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.window?.selectNextKeyView(nil)
        }
    }
}

private struct PreviewRecoveryUITestHost: View {
    @State private var state = CapturePreviewState.failed(
        failureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
    )

    var body: some View {
        if state == .released {
            Text(verbatim: "Preview Closed")
                .accessibilityIdentifier("capture_preview_closed_state")
        } else {
            CapturePreviewRecoveryView(
                state: state,
                isRetrying: state == .restarting,
                retry: { state = .restarting },
                close: { state = .released }
            )
        }
    }
}

@MainActor
private enum AppTerminationCleanup {
    private static var handler: (() -> Void)?

    static func install(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    static func run() {
        guard let handler else { return }
        self.handler = nil
        handler()
    }
}

@MainActor
private final class VoidDisplayApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_: Notification) {
        AppTerminationCleanup.run()
    }
}

@MainActor
package enum AppSingleInstanceGuard {
    package enum LockAcquisitionResult: Equatable, Sendable {
        case acquired
        case heldByOtherInstance
        case failed(errorCode: Int32)
    }

    private static var lockFileDescriptor: Int32 = -1

    static func acquireSingleInstanceLockOrExit() {
        switch acquireSingleInstanceLock(bundleIdentifier: Bundle.main.bundleIdentifier) {
        case .acquired:
            return
        case .heldByOtherInstance:
            activateExistingApplication(
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
            exit(EXIT_SUCCESS)
        case let .failed(errorCode):
            AppLog.general.error(
                "Single-instance lock failed with errno \(errorCode, privacy: .public); continuing startup."
            )
        }
    }

    package static func lockFileName(bundleIdentifier: String?) -> String {
        let rawName = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "voiddisplay"
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitizedName = String(rawName.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "_"
        })
        return "\(sanitizedName).single-instance.lock"
    }

    private static func acquireSingleInstanceLock(bundleIdentifier: String?) -> LockAcquisitionResult {
        if lockFileDescriptor >= 0 {
            return .acquired
        }

        guard let lockFileURL = lockFileURL(bundleIdentifier: bundleIdentifier) else {
            return .failed(errorCode: EIO)
        }
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return classifyLockAttempt(
                openedDescriptor: descriptor,
                flockResult: nil,
                errorCode: errno
            )
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let flockResult = flock(descriptor, LOCK_EX | LOCK_NB)
        guard flockResult == 0 else {
            let errorCode = errno
            close(descriptor)
            return classifyLockAttempt(
                openedDescriptor: descriptor,
                flockResult: flockResult,
                errorCode: errorCode
            )
        }

        lockFileDescriptor = descriptor
        writeCurrentProcessIdentifier(to: descriptor)
        return .acquired
    }

    package static func classifyLockAttempt(
        openedDescriptor: Int32,
        flockResult: Int32?,
        errorCode: Int32
    ) -> LockAcquisitionResult {
        guard openedDescriptor >= 0 else {
            return .failed(errorCode: errorCode)
        }
        guard let flockResult else {
            return .failed(errorCode: EINVAL)
        }
        guard flockResult != 0 else {
            return .acquired
        }
        return classifyFlockFailure(errorCode: errorCode)
    }

    private static func classifyFlockFailure(errorCode: Int32) -> LockAcquisitionResult {
        if errorCode == EWOULDBLOCK {
            return .heldByOtherInstance
        }
        return .failed(errorCode: errorCode)
    }

    private static func lockFileURL(bundleIdentifier: String?) -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let lockDirectoryURL = applicationSupportURL.appendingPathComponent("VoidDisplay", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: lockDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        return lockDirectoryURL.appendingPathComponent(
            lockFileName(bundleIdentifier: bundleIdentifier),
            isDirectory: false
        )
    }

    private static func writeCurrentProcessIdentifier(to descriptor: Int32) {
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        let pidText = "\(ProcessInfo.processInfo.processIdentifier)\n"
        pidText.withCString { pointer in
            _ = write(descriptor, pointer, strlen(pointer))
        }
    }

    private static func activateExistingApplication(currentProcessIdentifier: pid_t, bundleIdentifier: String?) {
        guard let bundleIdentifier else {
            return
        }

        NSWorkspace.shared.runningApplications
            .first {
                $0.processIdentifier != currentProcessIdentifier
                    && $0.bundleIdentifier == bundleIdentifier
            }?
            .activate(options: [.activateAllWindows])
    }

}
