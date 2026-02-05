//
//  Resolution.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/11/28.
//

import Foundation

extension Resolutions{
    var id: String { rawValue }
    var resolutions: (Int,Int){
        let temp=self.rawValue.split(separator: "_")
        let (width,height)=(temp[1],temp[2])
        let resolution = (Int(width)!,Int(height)!)
        return resolution
    }
    
}
