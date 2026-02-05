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
    @EnvironmentObject var appHelper:AppHelper
    @State var displays:[SCDisplay]?
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) private var openURL
    @State private var hasScreenCapturePermission: Bool?
    @State private var isLoadingDisplays = false
    @State private var loadErrorMessage: String?
    @State private var showDebugInfo = false
    var body: some View {
        Group{
            if hasScreenCapturePermission == false {
                screenCapturePermissionView
            } else if let displays=displays{
                List(displays,id:\.self){display in
                    HStack{
                        Image(systemName: "display")
                            .font(.system(size: 40))
                        VStack(alignment: .leading,spacing:5){
                            VStack(alignment: .leading){
                                
                                if #available(macOS 26.0, *) {
                                    Text(NSScreen.screens.filter({item in
                                        item.cgDirectDisplayID==display.displayID
                                    }).first?.localizedName ?? "Monitor")
                                        .font(.headline)
//                                    Text(display.description)
//                                        .font(.callout)
                                }else{
                                    Text("Monitor")
                                        .font(.headline)
//                                    Text(display.description)
//                                        .font(.headline)
                                }
                                
                                    
                                Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
                                    .font(.subheadline)
                            }
                            if !appHelper.displays.filter({item in
                                item.displayID==display.displayID
                            }).isEmpty{
                                Text("Virtual Display")
                                    .font(.caption)
                                    .padding(3)
                                    .padding(.horizontal,5)
                                    .background(.gray.opacity(0.2),in: .capsule)
                            }else{
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
                                
                                let screenCapture=await creatScreenCapture(display: display)
                                
                                appHelper.screenCaptureObjects.append(screenCapture)
                                openWindow(value: Int(appHelper.screenCaptureObjects.firstIndex(of: screenCapture)!))
                            }
                        })
                    }
                }
                .safeAreaInset(edge: .bottom, content: {
                    VStack{
                        if #available(macOS 26.0, *) {}else{
                        Text("The system is lower than macOS 26 and cannot display the monitor name. Replaced with 'Monitor'.")
                            .font(.footnote)
                        }
                        Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                            .font(.footnote)
                    }
                    .padding()
                })
            } else if isLoadingDisplays || hasScreenCapturePermission == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Text("No watchable screen")
                    if let loadErrorMessage {
                        Text(loadErrorMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    Button("Retry") {
                        refreshPermissionAndMaybeLoad()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
        }
            .onAppear{
                refreshPermissionAndMaybeLoad()
            }
    }

    private var screenCapturePermissionView: some View {
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
                    openScreenCapturePrivacySettings()
                }
                Button("Request Permission") {
                    requestScreenCapturePermission()
                }
            }

            HStack(spacing: 12) {
                Button("Refresh") {
                    refreshPermissionAndMaybeLoad()
                }
                .controlSize(.small)

                Button("Retry") {
                    // User-initiated retry: attempt to load the display list.
                    // If permission is still missing, macOS may prompt here (expected).
                    loadDisplays()
                }
                .controlSize(.small)
            }

            Text("After granting permission, you may need to quit and relaunch the app.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            DisclosureGroup("Debug Info", isExpanded: $showDebugInfo) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bundle ID")
                        Text(verbatim: Bundle.main.bundleIdentifier ?? "-")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Path")
                        Text(verbatim: Bundle.main.bundleURL.path)
                    }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func openScreenCapturePrivacySettings() {
        // Best-effort deep link; exact pane may vary by macOS version.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    private func requestScreenCapturePermission() {
        let granted = CGRequestScreenCaptureAccess()
        hasScreenCapturePermission = granted
        if granted {
            loadDisplays()
        }
    }

    private func refreshPermissionAndMaybeLoad() {
        let granted = CGPreflightScreenCaptureAccess()
        hasScreenCapturePermission = granted
        if granted {
            loadDisplays()
        }
    }

    private func loadDisplays() {
        isLoadingDisplays = true
        loadErrorMessage = nil
        displays = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run {
                    self.displays = content.displays
                }
            } catch {
                await MainActor.run {
                    loadErrorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isLoadingDisplays = false
            }
        }
    }
}

struct IsCapturing: View {
    @EnvironmentObject var appHelper:AppHelper
    @State var showAddView=false
    @State var showErrorAlert=false
//    @Environment(\.openWindow) var openWindow
    var body: some View {
        Group{
            
            if !appHelper.screenCaptureObjects.isEmpty{
                    List(appHelper.screenCaptureObjects,id:\.self){screenCaptureObject in
                        if let capture=screenCaptureObject{
                            HStack{
                                Text(capture.description)
                                Spacer()
                                Button("Destroy",action:{
                                    guard let index = appHelper.screenCaptureObjects.firstIndex(of: screenCaptureObject) else {
                                        showErrorAlert=true
                                        return
                                    }
                                    appHelper.screenCaptureObjects[Int(index)]?.stopCapture()
                                    appHelper.screenCaptureObjects[Int(index)]=nil
                                    
                                })
                                .foregroundStyle(.red)
                            }
                        }
                    }
            }else{
                Text("")
            }
            
            
        }
        .alert("Error", isPresented: $showErrorAlert, actions: {Button("OK"){}}, message: {Text("Cannot destroy this window")})
        .toolbar{
            ToolbarItem(content: {
                Button(action:{
                    showAddView=true
                }){
                    Label("Listening window", systemImage: "plus")
                }
                .popover(isPresented: $showAddView, content: {
                    CaptureChoose()
                        .frame(width: 500,height: 400)
                })
            })
        }
    }
}

#Preview {
    CaptureChoose()
}
