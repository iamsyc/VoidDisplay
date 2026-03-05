import Foundation

enum TestPortAllocator {
    private static let portRange: ClosedRange<UInt16> = 20_000...59_999

    static func randomUnprivilegedPort() -> UInt16 {
        randomPortCandidates(count: 1).first ?? 20_000
    }

    static func randomPortCandidates(count: Int) -> [UInt16] {
        guard count > 0 else { return [] }

        let boundedCount = min(
            count,
            Int(portRange.upperBound - portRange.lowerBound + 1)
        )
        var generator = SystemRandomNumberGenerator()
        var used = Set<UInt16>()
        var ports: [UInt16] = []
        ports.reserveCapacity(boundedCount)

        while ports.count < boundedCount {
            let candidate = UInt16.random(in: portRange, using: &generator)
            guard used.insert(candidate).inserted else { continue }
            ports.append(candidate)
        }
        return ports
    }
}
