//
//  Resolution.swift
//  VoidDisplay
//
//

import Foundation

package extension DisplayResolutionPreset {
    // Compatibility shim for existing callers.
    var resolutions: (Int, Int) {
        let size = logicalSize
        return (size.width, size.height)
    }
}
