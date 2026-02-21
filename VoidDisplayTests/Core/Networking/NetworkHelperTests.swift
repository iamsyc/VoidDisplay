import Foundation
import Testing
@testable import VoidDisplay

struct NetworkHelperTests {

    @Test func selectPreferredLANIPv4AddressUsesPreferredInterfaceOrder() {
        let candidates = [
            LANIPv4Candidate(name: "en2", address: "10.0.0.3"),
            LANIPv4Candidate(name: "en1", address: "10.0.0.2")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "10.0.0.2")
    }

    @Test func selectPreferredLANIPv4AddressPrefersEn0WhenPresent() {
        let candidates = [
            LANIPv4Candidate(name: "bridge0", address: "192.168.50.2"),
            LANIPv4Candidate(name: "en0", address: "192.168.1.99"),
            LANIPv4Candidate(name: "en1", address: "192.168.1.88")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "192.168.1.99")
    }

    @Test func selectPreferredLANIPv4AddressFallsBackToFirstCandidate() {
        let candidates = [
            LANIPv4Candidate(name: "utun3", address: "100.64.0.3"),
            LANIPv4Candidate(name: "utun4", address: "100.64.0.4")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "100.64.0.3")
    }

    @Test func selectPreferredLANIPv4AddressReturnsNilForEmptyCandidates() {
        #expect(selectPreferredLANIPv4Address(from: []) == nil)
    }
}
