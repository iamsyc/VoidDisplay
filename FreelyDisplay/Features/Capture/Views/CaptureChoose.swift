//
//  CaptureChoose.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/5.
//

import SwiftUI
import ScreenCaptureKit
import Cocoa
import CoreGraphics

struct CaptureChoose: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State private var viewModel = CaptureChooseViewModel()
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group{
            if viewModel.hasScreenCapturePermission == false {
                screenCapturePermissionView
            } else if let displays = viewModel.displays {
                List(displays,id:\.self){display in
                    HStack{
                        Image(systemName: "display")
                            .font(.system(size: 40))
                            VStack(alignment: .leading,spacing:5){
                                VStack(alignment: .leading){
                                    Text(viewModel.displayName(for: display))
                                        .font(.headline)
                                    Text(viewModel.resolutionText(for: display))
                                        .font(.subheadline)
                                }
                                if viewModel.isVirtualDisplay(display, appHelper: appHelper) {
                                    Text("Virtual Display")
                                        .font(.caption)
                                        .padding(3)
                                        .padding(.horizontal,5)
                                        .background(.gray.opacity(0.2),in: .capsule)
                                } else {
                                    Text("Physical Display or other Virtual Display")
                                        .font(.caption)
                                        .padding(3)
                                        .padding(.horizontal,5)
                                        .background(.gray.opacity(0.2),in: .capsule)
                                }
                            }
                            .padding(.bottom,5)
                        Spacer()
                        Button("Monitor Display",action:{
                            Task{
                                await viewModel.startMonitoring(
                                    display: display,
                                    appHelper: appHelper
                                ) { sessionId in
                                    openWindow(value: sessionId)
                                }
                            }
                        })
                    }
                }
                .safeAreaInset(edge: .bottom, content: {
                    VStack{
                        Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                            .font(.footnote)
                    }
                    .padding()
                })
            } else if viewModel.isLoadingDisplays || viewModel.hasScreenCapturePermission == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Text("No watchable screen")
                    if let loadErrorMessage = viewModel.loadErrorMessage {
                        Text(loadErrorMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    Button("Retry") {
                        viewModel.refreshPermissionAndMaybeLoad()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
        }
            .onAppear{
                viewModel.refreshPermissionAndMaybeLoad()
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
                        viewModel.requestScreenCapturePermission()
                    }
                }

                HStack(spacing: 12) {
                    Button("Refresh") {
                        viewModel.refreshPermissionAndMaybeLoad()
                    }
                    .controlSize(.small)

                    Button("Retry") {
                        // User-initiated retry: attempt to load the display list.
                        // If permission is still missing, macOS may prompt here (expected).
                        viewModel.loadDisplays()
                    }
                    .controlSize(.small)
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
}

struct IsCapturing: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
    @State var showAddView = false

    var body: some View {
        Group {
            if !appHelper.screenCaptureSessions.isEmpty {
                List(appHelper.screenCaptureSessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(session.displayName)
                                    .font(.headline)
                                if session.isVirtualDisplay {
                                    Text("Virtual Display")
                                        .font(.caption)
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, 6)
                                        .background(.gray.opacity(0.2), in: .capsule)
                                }
                            }
                            Text(session.resolutionText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Destroy",action:{
                            appHelper.removeMonitoringSession(id: session.id)
                        })
                        .foregroundStyle(.red)
                    }
                }
            } else {
                Text("No Listening Windows")
                    .foregroundColor(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(content: {
                Button(action: {
                    showAddView = true
                }) {
                    Label("Listening window", systemImage: "plus")
                }
                .popover(isPresented: $showAddView, content: {
                    CaptureChoose()
                        .frame(width: 500, height: 400)
                })
            })
        }
    }
}

#Preview {
    CaptureChoose()
        .environment(AppHelper(preview: true))
}
