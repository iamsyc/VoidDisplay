//
//  creatVirtualDisplay.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Cocoa
import CoreGraphics

struct creatVirtualDisplay: View {
    @State var name="Virtual Display"
    @State var serialNum=1
    @Binding var isShow:Bool
    @State var serialNumError=false
    @State var customSerialNumError=false
    @State var selectedResolution:Resolutions = .r_1920_1080
    @EnvironmentObject var appHelper:AppHelper
    var body: some View {
        Form{
            TextField("Name", text:$name)
            TextField("Serial Number", value: $serialNum, format: .number)
                .disabled(!customSerialNumError)
            Toggle("Custom Serial Number", isOn: $customSerialNumError)
            Picker(selection: $selectedResolution, label: Text("Resolution")) {
                ForEach(Resolutions.allCases){someCase in
                    Text("\(String(someCase.resolutions.0)) × \(String(someCase.resolutions.1))")
                        .tag(someCase)
                }
            }
            
        }
        .padding()
        .toolbar{
            ToolbarItem(placement: .confirmationAction, content: {
                Button("Creat",action:{
                    if appHelper.displays.filter({item in
                        Int(item.serialNum)==serialNum
                    }).isEmpty{
                        makeVirtualDisplay()
                    }else{
                        serialNumError=true
                    }
                })
            })
            ToolbarItem(placement: .cancellationAction, content: {
                Button("Cancel",action:{
                    isShow=false
                })
            })
        }
        .alert(Text("Error"), isPresented: $serialNumError, actions: {Button("OK"){}}, message: {Text("This serial number has already been used.")})
        .onAppear{
//            serialNum=Int(UInt32.random(in: 0...4294967295))
            let _ = appHelper.displays.map({item in
                if serialNum<=Int(item.serialNum){
                    serialNum += 1
                }
            })
        }
//        .navigationTitle("新建虚拟显示器")
    }
    private func makeVirtualDisplay(){
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { a, b in
            NSLog("\(String(describing: a)), \(String(describing: b))")
        }
        desc.name = name
        desc.maxPixelsWide = 1800*4
        desc.maxPixelsHigh = 1012*4
        desc.sizeInMillimeters = CGSize(width: 1800*4, height: 1012*4)
        desc.productID = 0x1234
        desc.vendorID = 0x3456
        desc.serialNum = UInt32(serialNum)

        let display = CGVirtualDisplay(descriptor: desc)

        let (width,height)=(selectedResolution.resolutions.0,selectedResolution.resolutions.1)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1000
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 120),
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 30),
        ]
        appHelper.displays.append(display)
        //self.display = display
        display.apply(settings)
        
        isShow=false
    }
}

#Preview {
//    creatVirtualDisplay( isShow: .constant(true))
}


