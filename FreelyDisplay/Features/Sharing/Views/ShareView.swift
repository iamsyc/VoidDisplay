//
//  shareView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/16.
//

import SwiftUI
import ScreenCaptureKit
import Network
import Cocoa

struct ShareView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = ShareViewModel()

    var body: some View {
        Group {
            if !appHelper.isWebServiceRunning {
                VStack(spacing: 16) {
                    Text("Web service is off")
                        .font(.title2)
                    Button("Start service") {
                        viewModel.startService(appHelper: appHelper)
                    }
                }
            } else if appHelper.isSharing {
                VStack(spacing: 20) {
                    Text("Sharing in progress")
                        .font(.largeTitle)
                    Button {
                        appHelper.stopSharing()
                    } label: {
                        Text("Stop sharing")
                    }
                    .foregroundStyle(.red)
                }
            } else {
                Group {
                    if viewModel.isLoadingDisplays {
                        ProgressView("Loading…")
                    } else if let displays = viewModel.displays {
                        if displays.isEmpty {
                            Text("No screen to share")
                        } else {
                            List(displays, id: \.self) { display in
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
                                        if !appHelper.displays.filter({ item in
                                            item.displayID == display.displayID
                                        }).isEmpty {
                                            Text("Virtual Display")
                                                .font(.caption)
                                                .padding(3)
                                                .padding(.horizontal, 5)
                                                .background(.gray.opacity(0.2), in: .capsule)
                                        } else {
                                            Text("Physical Display or other Virtual Display")
                                                .font(.caption)
                                                .padding(3)
                                                .padding(.horizontal, 5)
                                                .background(.gray.opacity(0.2), in: .capsule)
                                        }
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
                                            Text("Sharing")
                                        }
                                    }
                                    .disabled(viewModel.startingDisplayID != nil)
                                }
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
                    }
                }
            }
        }
        .toolbar {
            if appHelper.isWebServiceRunning && !appHelper.isSharing {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    viewModel.refreshDisplays(appHelper: appHelper)
                }
            }
            if appHelper.isWebServiceRunning {
                Button("Open the page") {
                    viewModel.openSharePage(appHelper: appHelper)
                }
                Button("Close service") {
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
}

#Preview {
    ShareView()
        .environment(AppHelper(preview: true))
}
