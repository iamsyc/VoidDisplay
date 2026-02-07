//
//  shareView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/16.
//

import SwiftUI
import ScreenCaptureKit
import Cocoa

struct ShareView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = ShareViewModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSummary
            shareContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            if appHelper.isWebServiceRunning && !appHelper.isSharing {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    viewModel.refreshDisplays(appHelper: appHelper)
                }
            }
            if appHelper.isWebServiceRunning {
                Button("Open Share Page") {
                    viewModel.openSharePage(appHelper: appHelper)
                }
                Button("Stop Service") {
                    viewModel.stopService(appHelper: appHelper)
                }
            }
        }
        .onAppear {
            viewModel.refreshPermissionAndMaybeLoad(appHelper: appHelper)
        }
        .onChange(of: appHelper.isWebServiceRunning) { _, _ in
            viewModel.syncForCurrentState(appHelper: appHelper)
        }
        .onChange(of: appHelper.isSharing) { _, _ in
            viewModel.syncForCurrentState(appHelper: appHelper)
        }
        .alert("Error", isPresented: $viewModel.showOpenPageError) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.openPageErrorMessage)
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                statusTile(
                    title: String(localized: "Service"),
                    value: String(localized: appHelper.isWebServiceRunning ? "Running" : "Stopped"),
                    symbol: appHelper.isWebServiceRunning ? "network.badge.shield.half.filled" : "network.slash",
                    tint: appHelper.isWebServiceRunning ? .green : .secondary
                )
                statusTile(
                    title: String(localized: "Sharing"),
                    value: String(localized: appHelper.isSharing ? "Active" : "Idle"),
                    symbol: appHelper.isSharing ? "waveform.badge.mic" : "pause.circle",
                    tint: appHelper.isSharing ? .green : .secondary
                )
            }

            if appHelper.isWebServiceRunning {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Text("Address:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.sharePageAddress(appHelper: appHelper) ?? String(localized: "LAN IP unavailable"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var shareContent: some View {
        if viewModel.hasScreenCapturePermission == false {
            screenCapturePermissionView
        } else if viewModel.hasScreenCapturePermission == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !appHelper.isWebServiceRunning {
            VStack(alignment: .leading, spacing: 10) {
                Text("Web service is stopped.")
                    .font(.title3)
                Button("Start service") {
                    viewModel.startService(appHelper: appHelper)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        } else if appHelper.isSharing {
            sharingInProgressView
        } else if viewModel.isLoadingDisplays {
            ProgressView("Loading displays…")
                .padding(.horizontal, 16)
                .padding(.top, 6)
        } else if let displays = viewModel.displays {
            if displays.isEmpty {
                Text("No screen to share")
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            } else {
                List(displays, id: \.self) { display in
                    shareableDisplayRow(display)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        Divider()
                        Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
            }
        } else {
            Text("No screen to share")
                .padding(.horizontal, 16)
                .padding(.top, 6)
        }
    }

    private var screenCapturePermissionView: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("Screen Recording Permission Required")
                    .font(.headline)
                Text("Allow screen recording in System Settings to monitor displays.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: 12) {
                    Button("Open System Settings") {
                        viewModel.openScreenCapturePrivacySettings { url in
                            openURL(url)
                        }
                    }
                    Button("Request Permission") {
                        viewModel.requestScreenCapturePermission(appHelper: appHelper)
                    }
                }

                HStack(spacing: 12) {
                    Button("Refresh") {
                        viewModel.refreshPermissionAndMaybeLoad(appHelper: appHelper)
                    }
                    .controlSize(.small)

                    if viewModel.loadErrorMessage != nil || viewModel.lastLoadError != nil {
                        Button("Retry") {
                            // User-initiated retry: attempt to load the display list.
                            // If permission is still missing, macOS may prompt here (expected).
                            viewModel.loadDisplays()
                        }
                        .controlSize(.small)
                    }
                }

                if let loadErrorMessage = viewModel.loadErrorMessage {
                    Text(loadErrorMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                VStack(spacing: 6) {
                    Text("After granting permission, you may need to quit and relaunch the app.")
                    Text("If System Settings shows permission is ON but this page still says it is OFF, the change has not been applied to this running app process. Quit (⌘Q) and reopen, or remove and re-add the app in the permission list.")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

                DisclosureGroup("Debug Info", isExpanded: $viewModel.showDebugInfo) {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bundle ID")
                            Text(verbatim: Bundle.main.bundleIdentifier ?? "-")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App Path")
                            Text(verbatim: Bundle.main.bundleURL.path)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preflight Permission")
                            Text(verbatim: (viewModel.lastPreflightPermission ?? viewModel.hasScreenCapturePermission).map { $0 ? "true" : "false" } ?? "-")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Request Permission Result")
                            Text(verbatim: viewModel.lastRequestPermission.map { $0 ? "true" : "false" } ?? "-")
                        }
                        if let lastLoadError = viewModel.lastLoadError {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last Error")
                                Text(verbatim: lastLoadError.description)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Error Domain")
                                Text(verbatim: lastLoadError.domain)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Error Code")
                                Text(verbatim: "\(lastLoadError.code)")
                            }
                            if let failureReason = lastLoadError.failureReason, !failureReason.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Failure Reason")
                                    Text(verbatim: failureReason)
                                }
                            }
                            if let recoverySuggestion = lastLoadError.recoverySuggestion, !recoverySuggestion.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Recovery Suggestion")
                                    Text(verbatim: recoverySuggestion)
                                }
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
                }
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sharingInProgressView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 34, height: 34)
                    .background(.green.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sharing is in progress.")
                        .font(.headline)
                    Text("Your screen is currently being streamed to connected clients.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    appHelper.stopSharing()
                } label: {
                    Label("Stop sharing", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Open Share Page") {
                    viewModel.openSharePage(appHelper: appHelper)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func statusTile(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func shareableDisplayRow(_ display: SCDisplay) -> some View {
        HStack {
            Image(systemName: "display")
                .font(.system(size: 40))

            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading) {
                    let displayName = NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName
                        ?? String(localized: "Monitor")
                    Text(
                        displayName
                    )
                    .font(.headline)
                    Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
                        .font(.subheadline)
                }

                Text(
                    String(
                        localized: isManagedVirtualDisplay(display.displayID)
                            ? "Virtual Display"
                            : "Physical Display or other Virtual Display"
                    )
                )
                    .font(.caption)
                    .padding(3)
                    .padding(.horizontal, 5)
                    .background(.gray.opacity(0.2), in: .capsule)
            }
            .padding(.bottom, 5)

            Spacer()

            Button {
                Task {
                    await viewModel.startSharing(display: display, appHelper: appHelper)
                }
            } label: {
                if viewModel.startingDisplayID == display.displayID {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Share")
                }
            }
            .disabled(viewModel.startingDisplayID != nil)
        }
    }

    private func isManagedVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        appHelper.displays.contains(where: { $0.displayID == displayID })
    }
}

#Preview {
    ShareView()
        .environment(AppHelper(preview: true))
}
