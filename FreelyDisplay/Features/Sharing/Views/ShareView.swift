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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSummary
            shareContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            if appHelper.isWebServiceRunning && !appHelper.isSharing {
                Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
                    viewModel.refreshDisplays(appHelper: appHelper)
                }
            }
            if appHelper.isWebServiceRunning {
                Button(String(localized: "Open Share Page")) {
                    viewModel.openSharePage(appHelper: appHelper)
                }
                Button(String(localized: "Stop Service")) {
                    viewModel.stopService(appHelper: appHelper)
                }
            }
        }
        .onAppear {
            viewModel.syncForCurrentState(appHelper: appHelper)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Status"))
                .font(.headline)

            HStack(spacing: 8) {
                statusChip(
                    title: String(localized: "Service"),
                    value: String(localized: appHelper.isWebServiceRunning ? "Running" : "Stopped"),
                    tint: appHelper.isWebServiceRunning ? .green : .secondary
                )
                statusChip(
                    title: String(localized: "Sharing"),
                    value: String(localized: appHelper.isSharing ? "Active" : "Idle"),
                    tint: appHelper.isSharing ? .green : .secondary
                )
            }

            if appHelper.isWebServiceRunning {
                HStack(spacing: 6) {
                    Text(String(localized: "Address:"))
                    Text(viewModel.sharePageAddress(appHelper: appHelper) ?? String(localized: "LAN IP unavailable"))
                        .textSelection(.enabled)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var shareContent: some View {
        if !appHelper.isWebServiceRunning {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Web service is stopped."))
                    .font(.title3)
                Button(String(localized: "Start service")) {
                    viewModel.startService(appHelper: appHelper)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        } else if appHelper.isSharing {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Sharing is in progress."))
                    .font(.title3)
                Button(String(localized: "Stop sharing"), role: .destructive) {
                    appHelper.stopSharing()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        } else if viewModel.isLoadingDisplays {
            ProgressView(String(localized: "Loading displays…"))
                .padding(.horizontal, 16)
                .padding(.top, 6)
        } else if let displays = viewModel.displays {
            if displays.isEmpty {
                Text(String(localized: "No screen to share"))
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
            Text(String(localized: "No screen to share"))
                .padding(.horizontal, 16)
                .padding(.top, 6)
        }
    }

    private func statusChip(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }

    private func shareableDisplayRow(_ display: SCDisplay) -> some View {
        HStack {
            Image(systemName: "display")
                .font(.system(size: 40))

            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading) {
                    Text(
                        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? "Monitor"
                    )
                    .font(.headline)
                    Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
                        .font(.subheadline)
                }

                Text(isManagedVirtualDisplay(display.displayID) ? "Virtual Display" : "Physical Display or other Virtual Display")
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
                    Text(String(localized: "Share"))
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
