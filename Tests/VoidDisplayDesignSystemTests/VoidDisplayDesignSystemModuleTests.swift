import Testing
@testable import VoidDisplayDesignSystem

@Suite("VoidDisplayDesignSystem module")
struct VoidDisplayDesignSystemModuleTests {
    @Test func moduleLoads() {
        #expect(Bool(true))
    }
}
