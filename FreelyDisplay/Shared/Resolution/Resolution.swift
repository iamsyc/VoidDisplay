//
//  Resolution.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/11/28.
//

import Foundation

extension DisplayResolutionPreset {
    // Compatibility shim for existing callers.
    var resolutions: (Int, Int) {
        let size = logicalSize
        return (size.width, size.height)
    }
}
