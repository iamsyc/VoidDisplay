import Foundation
import VoidDisplayFoundation

package enum VirtualDisplayCreationTemplate: String, CaseIterable, Identifiable {
    case presentation
    case text
    case custom

    package var id: Self { self }

    package var title: String {
        switch self {
        case .presentation: String(localized: "Present and Share")
        case .text: String(localized: "Clear Text")
        case .custom: String(localized: "Custom")
        }
    }

    package var baseDisplayName: String {
        switch self {
        case .presentation: String(localized: "Presentation Display")
        case .text: String(localized: "Text Display")
        case .custom: String(localized: "Virtual Display")
        }
    }

    package var modes: [ResolutionSelection]? {
        switch self {
        case .presentation: [.init(preset: .w1920h1080, enableHiDPI: false)]
        case .text: [.init(preset: .w1920h1080, enableHiDPI: true)]
        case .custom: nil
        }
    }

    package func defaultName(serial: UInt32) -> String {
        CreateVirtualDisplayInputValidator.defaultName(baseName: baseDisplayName, serialNum: serial)
    }

    package func replacingName(_ name: String, from previous: Self, serial: UInt32) -> String {
        name == previous.defaultName(serial: serial) ? defaultName(serial: serial) : name
    }
}

package struct CreatedDisplayOutcome {
    package let configID: UUID
    package let shouldOpenPreview: Bool

    package init(configID: UUID, shouldOpenPreview: Bool) {
        self.configID = configID
        self.shouldOpenPreview = shouldOpenPreview
    }
}
