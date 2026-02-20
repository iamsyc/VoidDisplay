//
//  Resolution.swift
//  FreelyDisplay
//
//

import Foundation

extension DisplayResolutionPreset {
    // Compatibility shim for existing callers.
    var resolutions: (Int, Int) {
        let size = logicalSize
        return (size.width, size.height)
    }
}
