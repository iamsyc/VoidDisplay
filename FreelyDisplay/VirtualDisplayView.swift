//
//  VirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI

struct VirtualDisplayView: View {
    @EnvironmentObject var appHelper:AppHelper
    @State var creatView=false
    @State var editView=false
    @State var selectedDisplay: CGVirtualDisplay?
    
    var body: some View {
        Group{
            if !appHelper.displays.isEmpty{
                List(appHelper.displays,id: \.self){display in
                    HStack(alignment:.center){
                        Image(systemName: "display")
                            .font(.system(size: 30))
                        VStack(alignment: .leading){
                            Text(String(display.name))
    //                                .font(.title3)
                                .font(.headline)
                            Text(String(display.serialNum))
                                
                                .font(.subheadline)
                        }
                        Spacer()
                        HStack(spacing: 12){
                            Button("Edit", action:{
                                selectedDisplay = display
                                editView = true
                            })
                            Button("Destroy",action:{
                                appHelper.displays.removeAll { CGVirtualDisplay in
                                    CGVirtualDisplay == display
                                }
                                appHelper.id=UUID()
                            })
                            .foregroundStyle(.red)
                        }
                    }
                    .id(appHelper.id)
                }
            }else{
                Text("")
            }
        }
        
        .sheet(isPresented: $creatView, content: {creatVirtualDisplay(isShow: $creatView)})
        .sheet(isPresented: $editView, content: {
            if let display = selectedDisplay {
                EditDisplaySettingsView(display: display, isShow: $editView)
                    .environmentObject(appHelper)
            }
        })
        .toolbar{
            Button("Add Virtual Display", systemImage: "plus",action:{
                creatView=true
            })
        }
    }
}

#Preview {
    VirtualDisplayView()
}
