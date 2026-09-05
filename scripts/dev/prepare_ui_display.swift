import CoreGraphics
import Foundation

// Prepare the CI login session for the suite's 1180 × 720 windows and desktop controls.
let minimumSize = CGSize(width: 1280, height: 900)
let displayID = CGMainDisplayID()
let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? []

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[ERROR] UI desktop setup: \(message)\n".utf8))
    exit(1)
}

func desktopFits() -> Bool {
    let bounds = CGDisplayBounds(displayID)
    return bounds.width >= minimumSize.width && bounds.height >= minimumSize.height
}

print("[INFO] UI desktop before: \(CGDisplayBounds(displayID))")
print("[INFO] Available display modes: \(modes.map { "\($0.width)x\($0.height)" }.joined(separator: ", "))")

if !desktopFits() {
    guard let mode = modes
        .filter({ $0.width >= Int(minimumSize.width) && $0.height >= Int(minimumSize.height) })
        .min(by: { $0.width * $0.height < $1.width * $1.height })
    else {
        fail("No display mode can provide a 1280x900 desktop.")
    }

    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
        fail("Cannot begin display configuration.")
    }
    let configureResult = CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil)
    guard configureResult == .success else {
        CGCancelDisplayConfiguration(configuration)
        fail("Cannot select display mode: \(configureResult.rawValue).")
    }
    let result = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard result == .success else {
        fail("Cannot apply display mode to this login session: \(result.rawValue).")
    }

    let deadline = Date.now.addingTimeInterval(5)
    while !desktopFits(), Date.now < deadline {
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
    }
    guard desktopFits() else { fail("Display geometry did not reach the required size.") }
}

print("[INFO] UI desktop ready: \(CGDisplayBounds(displayID))")
