//
//  NetworkHelper.swift
//  VoidDisplay
//
//

import Foundation
import Darwin

// Project default actor isolation is MainActor; keep this helper executor-agnostic.
package nonisolated struct LANIPv4Candidate: Equatable, Sendable {
    package let name: String
    package let address: String
}

nonisolated private let preferredLANInterfaces = ["en0", "en1", "en2", "en3", "bridge0", "pdp_ip0"]

package nonisolated func selectPreferredLANIPv4Address(from candidates: [LANIPv4Candidate]) -> String? {
    candidates.enumerated()
        .min { lhs, rhs in
            let lhsRank = lanIPv4CandidateRank(lhs.element)
            let rhsRank = lanIPv4CandidateRank(rhs.element)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            let lhsPreferredIndex = preferredLANInterfaceIndex(lhs.element.name)
            let rhsPreferredIndex = preferredLANInterfaceIndex(rhs.element.name)
            if lhsPreferredIndex != rhsPreferredIndex {
                return lhsPreferredIndex < rhsPreferredIndex
            }

            return lhs.offset < rhs.offset
        }?
        .element
        .address
}

private nonisolated func lanIPv4CandidateRank(_ candidate: LANIPv4Candidate) -> Int {
    let name = candidate.name
    let isPrivate = isRFC1918IPv4Address(candidate.address)

    if isTunnelInterface(name) {
        return 5
    }
    if isPrivate, isEthernetInterface(name) {
        return 0
    }
    if isPrivate, isPhysicalOrBridgeInterface(name) {
        return 1
    }
    if isPrivate {
        return 2
    }
    if preferredLANInterfaceIndex(name) != Int.max {
        return 3
    }
    return 4
}

private nonisolated func preferredLANInterfaceIndex(_ name: String) -> Int {
    preferredLANInterfaces.firstIndex(of: name) ?? Int.max
}

private nonisolated func isEthernetInterface(_ name: String) -> Bool {
    name.hasPrefix("en")
}

private nonisolated func isPhysicalOrBridgeInterface(_ name: String) -> Bool {
    name.hasPrefix("bridge") || name.hasPrefix("pdp_ip")
}

private nonisolated func isTunnelInterface(_ name: String) -> Bool {
    name.hasPrefix("utun")
}

private nonisolated func isRFC1918IPv4Address(_ address: String) -> Bool {
    let octets = address.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4 else { return false }

    switch (octets[0], octets[1]) {
    case (10, _):
        return true
    case (172, 16...31):
        return true
    case (192, 168):
        return true
    default:
        return false
    }
}

/// Returns a best-effort LAN IPv4 address for opening the local share page.
/// - Note: The previous implementation only looked at `en0` (often Wi‑Fi), which
///   can be wrong on some Macs (e.g. Ethernet may be `en0`, Wi‑Fi may be `en1`),
///   and it could also return IPv6 which needs special URL formatting.
package nonisolated func getLANIPv4Address() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var candidates: [LANIPv4Candidate] = []

    for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ifptr.pointee

        let flags = Int32(interface.ifa_flags)
        let isUp = (flags & IFF_UP) != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0
        guard isUp, !isLoopback else { continue }

        guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

        let name = String(cString: interface.ifa_name)
        if name == "awdl0" || name == "llw0" { continue }

        var ipv4Addr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4Addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }

        let ip = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        if ip.hasPrefix("169.254.") { continue } // link-local (usually not reachable by other devices)
        candidates.append(.init(name: name, address: ip))
    }

    return selectPreferredLANIPv4Address(from: candidates)
}
