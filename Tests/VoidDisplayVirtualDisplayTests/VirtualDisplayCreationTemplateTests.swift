import Foundation
import Testing
@testable import VoidDisplayVirtualDisplay

@MainActor
struct VirtualDisplayCreationTemplateTests {
    @Test func templatePixelsMatchTheIntendedWorkspaces() throws {
        let presentation = try #require(VirtualDisplayCreationTemplate.presentation.modes?.first)
        let text = try #require(VirtualDisplayCreationTemplate.text.modes?.first)
        #expect(presentation.width == 1920 && presentation.height == 1080)
        #expect(presentation.refreshRate == 60 && !presentation.enableHiDPI)
        #expect(text.width == 1920 && text.height == 1080)
        #expect(text.refreshRate == 60 && text.enableHiDPI)
        #expect(VirtualDisplayCreationTemplate.custom.modes == nil)
    }

    @Test func switchingTemplatesPreservesEditedNames() {
        let previous = VirtualDisplayCreationTemplate.presentation
        let next = VirtualDisplayCreationTemplate.text
        #expect(next.replacingName("My slides", from: previous, serial: 4) == "My slides")
        #expect(next.replacingName(previous.defaultName(serial: 4), from: previous, serial: 4) == next.defaultName(serial: 4))
    }
}
