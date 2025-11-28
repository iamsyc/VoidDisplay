//
//  CaptureChoose.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/5.
//

import SwiftUI
import ScreenCaptureKit
import Cocoa

struct CaptureChoose: View {
    @EnvironmentObject var appHelper:AppHelper
    @State var displays:[SCDisplay]?
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Group{
            if let displays=displays{
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
            }else{
                Text("No watchable screen")
            }
            
        }
            .onAppear{
                Task{
                    let content = try? await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: false)
                    guard let displays = content?.displays else { return }
                    self.displays=displays
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
