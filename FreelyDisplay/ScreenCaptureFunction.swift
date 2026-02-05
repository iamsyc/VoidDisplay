//
//  ScreenCapture.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import Foundation
import ScreenCaptureKit
import Combine
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ScreenCaptureSession {
    let stream: SCStream
    let delegate: StreamDelegate
}
    
func creatScreenCapture(display:SCDisplay,showsCursor:Bool=true,excludedOtherApps:[SCRunningApplication]=[],exceptingOtherWindows:[SCWindow]=[]) async -> ScreenCaptureSession {

    
    let streamConfig = SCStreamConfiguration()
            

    streamConfig.width = display.width*4
    streamConfig.height = display.height*4

    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(60))

    streamConfig.showsCursor = showsCursor

    streamConfig.capturesAudio = false
    

    
    let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    
    

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
    
    return ScreenCaptureSession(stream: stream, delegate: delegate)
        

        
}
    


class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print(error.localizedDescription)
    }
}


class Capture:NSObject,SCStreamOutput,ObservableObject{
    @Published var surface:CVImageBuffer?
    var jpgData:Data?
    private let encodingQueue = DispatchQueue(label: "phineas.mac.FreelyDisplay.capture.jpeg", qos: .userInitiated)
    private let ciContext = CIContext()
    private let jpegScale: CGFloat = 0.25

    private func encodeJPEG(from pixelBuffer: CVImageBuffer) -> Data? {
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let outputImage = ciImage.transformed(by: CGAffineTransform(scaleX: jpegScale, y: jpegScale))
            guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else { return nil }

            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }

            let options = [kCGImageDestinationLossyCompressionQuality as String: 0.65] as CFDictionary
            CGImageDestinationAddImage(destination, cgImage, options)
            return CGImageDestinationFinalize(destination) ? (mutableData as Data) : nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }


        // Get the backing IOSurface.
//        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        
        // Keep UI updates on main thread.
        self.surface = pixelBuffer

        // Encode JPEG off-main, but publish the result back on main to avoid data races with readers.
        encodingQueue.async { [weak self] in
            guard let self else { return }
            let encoded = self.encodeJPEG(from: pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.jpgData = encoded
            }
        }
        
        

    }
}
