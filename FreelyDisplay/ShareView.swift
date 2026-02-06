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
    @State var displays:[SCDisplay]?
    @State private var showOpenPageError = false
    @State private var openPageErrorMessage = ""

    var body: some View {
        Group {
            if !appHelper.isWebServiceRunning {
                VStack(spacing: 16) {
                    Text("Web service is off")
                        .font(.title2)
                    Button("Start service") {
                        if !appHelper.startWebService() {
                            openPageErrorMessage = String(localized: "Failed to start web service.")
                            showOpenPageError = true
                            return
                        }
                    }
                }
            } else if !appHelper.isSharing {
                Group {
                    if let displays = displays {
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
                                Button("Sharing") {
                                    Task {
                                        guard appHelper.isWebServiceRunning || appHelper.startWebService() else {
                                            await MainActor.run {
                                                openPageErrorMessage = String(localized: "Web service is not running.")
                                                showOpenPageError = true
                                            }
                                            return
                                        }

                                        let captureSession = await creatScreenCapture(display: display)
                                        let stream = Capture()
                                        do {
                                            try captureSession.stream.addStreamOutput(stream, type: .screen, sampleHandlerQueue: .main)
                                            try await captureSession.stream.startCapture()
                                            await MainActor.run {
                                                appHelper.beginSharing(stream: captureSession.stream, output: stream, delegate: captureSession.delegate)
                                            }
                                        } catch {
                                            await MainActor.run {
                                                appHelper.stopSharing()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 10) {
                                Divider()
                                Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button("Open the page") {
                                        openSharePage()
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Close service") {
                                        appHelper.stopWebService()
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                        }
                    } else {
                        Text("No screen to share")
                    }
                }
                .onAppear {
                    Task {
                        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                        guard let displays = content?.displays else { return }
                        self.displays = displays
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Text("Sharing in progress")
                        .font(.largeTitle)
                    HStack {
                        Button {
                            appHelper.stopSharing()
                        } label: {
                            Text("Stop sharing")
                        }
                        .foregroundStyle(.red)
                        Button {
                            openSharePage()
                        } label: {
                            Text("Open the page")
                        }
                        Button {
                            appHelper.stopWebService()
                        } label: {
                            Text("Close service")
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: $showOpenPageError) {
            Button("OK") {}
        } message: {
            Text(openPageErrorMessage)
        }
    }

    private func openSharePage() {
        guard appHelper.isWebServiceRunning else {
            openPageErrorMessage = String(localized: "Web service is not running.")
            showOpenPageError = true
            return
        }
        guard let ip = getWiFiIPAddress() else {
            openPageErrorMessage = String(localized: "No available LAN IP address was found. Please connect to Wi-Fi/Ethernet and try again.")
            showOpenPageError = true
            return
        }
        let urlString = "http://\(ip):\(appHelper.webServicePortValue)"
        guard let url = URL(string: urlString) else {
            openPageErrorMessage = String(localized: "Failed to build URL: \(urlString)")
            showOpenPageError = true
            return
        }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ShareView()
        .environment(AppHelper(preview: true))
}
