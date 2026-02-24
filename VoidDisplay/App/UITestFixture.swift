//
//  UITestFixture.swift
//  VoidDisplay
//

import Foundation

enum UITestFixture {
    static func virtualDisplayConfigs() -> [VirtualDisplayConfig] {
        [
            VirtualDisplayConfig(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                name: "虚拟显示器 13 寸",
                serialNum: 1,
                physicalWidth: 286,
                physicalHeight: 179,
                modes: [
                    .init(width: 1440, height: 900, refreshRate: 60, enableHiDPI: false)
                ],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                name: "虚拟显示器 14 寸",
                serialNum: 2,
                physicalWidth: 309,
                physicalHeight: 174,
                modes: [
                    .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
                ],
                desiredEnabled: true
            )
        ]
    }
}
