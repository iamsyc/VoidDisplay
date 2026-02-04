//
//  ScreenCapture.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import Foundation
import ScreenCaptureKit
import Combine

    
func creatScreenCapture(display:SCDisplay,showsCursor:Bool=true,excludedOtherApps:[SCRunningApplication]=[],exceptingOtherWindows:[SCWindow]=[]) async -> SCStream {

    
    let streamConfig = SCStreamConfiguration()
            

    streamConfig.width = display.width*4
    streamConfig.height = display.height*4

    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(60))

    streamConfig.showsCursor = showsCursor

    streamConfig.capturesAudio = false
    

    
    let content = try? await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    
    

    var excludedApps = content?.applications.filter { app in
        Bundle.main.bundleIdentifier == app.bundleIdentifier
    } ?? []
    excludedApps.append(contentsOf: excludedOtherApps)
    

    let filter = SCContentFilter(display: display,
                                excludingApplications: excludedApps,
                                exceptingWindows: exceptingOtherWindows)
    let delegate = StreamDelegate()
    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)
    
//    try? stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
    
    return stream
        

        
}
    


class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print(error.localizedDescription)
    }
}


class Capture:NSObject,SCStreamOutput,ObservableObject{
    @Published var surface:CVImageBuffer?
    var jpgData:Data?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }


        // Get the backing IOSurface.
//        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        
        DispatchQueue.global().async {
            self.surface=pixelBuffer
            let ciImage = CIImage(cvPixelBuffer: self.surface!)
            let context=CIContext()
            let streamCGImage=context.createCGImage(ciImage, from: ciImage.extent)
            self.jpgData=NSImage(cgImage: streamCGImage!, size: NSSize(width: streamCGImage!.width/4, height: streamCGImage!.height/4)).jpgRepresentation
        }
        
        

    }
}
