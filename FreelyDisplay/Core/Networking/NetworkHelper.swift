//
//  NetworkHelper.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/11/8.
//

import Foundation
import Darwin

struct LANIPv4Candidate: Equatable {
    let name: String
    let address: String
}

private let preferredLANInterfaces = ["en0", "en1", "en2", "en3", "bridge0", "pdp_ip0"]

func selectPreferredLANIPv4Address(from candidates: [LANIPv4Candidate]) -> String? {
    for preferred in preferredLANInterfaces {
        if let match = candidates.first(where: { $0.name == preferred }) {
            return match.address
        }
    }
    return candidates.first?.address
}

/// Returns a best-effort LAN IPv4 address for opening the local share page.
/// - Note: The previous implementation only looked at `en0` (often Wi‑Fi), which
///   can be wrong on some Macs (e.g. Ethernet may be `en0`, Wi‑Fi may be `en1`),
///   and it could also return IPv6 which needs special URL formatting.
func getLANIPv4Address() -> String? {
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

        let ip = String(cString: buffer)
        if ip.hasPrefix("169.254.") { continue } // link-local (usually not reachable by other devices)
        candidates.append(.init(name: name, address: ip))
    }

    return selectPreferredLANIPv4Address(from: candidates)
}
