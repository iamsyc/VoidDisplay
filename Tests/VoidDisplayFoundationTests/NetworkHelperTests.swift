@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

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

    @Test func selectPreferredLANIPv4AddressFallsBackToFirstTunnelCandidateWhenOnlyTunnelsExist() {
        let candidates = [
            LANIPv4Candidate(name: "utun3", address: "100.64.0.3"),
            LANIPv4Candidate(name: "utun4", address: "100.64.0.4")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "100.64.0.3")
    }

    @Test func selectPreferredLANIPv4AddressPrefersPrivateEthernetOverEarlierTunnel() {
        let candidates = [
            LANIPv4Candidate(name: "utun3", address: "10.8.0.2"),
            LANIPv4Candidate(name: "en1", address: "192.168.1.20")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "192.168.1.20")
    }

    @Test func selectPreferredLANIPv4AddressPrefersPrivateBridgeOverPublicPreferredInterface() {
        let candidates = [
            LANIPv4Candidate(name: "en0", address: "203.0.113.5"),
            LANIPv4Candidate(name: "bridge0", address: "192.168.64.1")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "192.168.64.1")
    }

    @Test func selectPreferredLANIPv4AddressPrefersOtherPrivateAddressOverPublicPreferredInterface() {
        let candidates = [
            LANIPv4Candidate(name: "en0", address: "203.0.113.5"),
            LANIPv4Candidate(name: "usb0", address: "172.16.0.5")
        ]

        let selected = selectPreferredLANIPv4Address(from: candidates)

        #expect(selected == "172.16.0.5")
    }

    @Test func selectPreferredLANIPv4AddressReturnsNilForEmptyCandidates() {
        #expect(selectPreferredLANIPv4Address(from: []) == nil)
    }
}
