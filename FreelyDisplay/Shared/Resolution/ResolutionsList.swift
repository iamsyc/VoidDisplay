//
//  ResolutionList.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/11/28.
//

import Foundation

enum DisplayResolutionPreset: String, CaseIterable, Identifiable {
    case w1512h982
    case w1352h878
    case w1147h745
    case w1512h945
    case w1280h800
    case w1440h900
    case w1920h1080
    case w1920h1200

    var id: String { rawValue }

    var logicalSize: (width: Int, height: Int) {
        switch self {
        case .w1512h982:
            return (1512, 982)
        case .w1352h878:
            return (1352, 878)
        case .w1147h745:
            return (1147, 745)
        case .w1512h945:
            return (1512, 945)
        case .w1280h800:
            return (1280, 800)
        case .w1440h900:
            return (1440, 900)
        case .w1920h1080:
            return (1920, 1080)
        case .w1920h1200:
            return (1920, 1200)
        }
    }

    var displayText: String {
        let size = logicalSize
        return "\(size.width) × \(size.height)"
    }
}

typealias Resolutions = DisplayResolutionPreset
