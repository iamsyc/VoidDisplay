@testable import VoidDisplayFoundation
import Foundation

enum AsyncTestTimeouts {
    static let shortStabilityWindow: UInt64 = 1_500_000_000
    static let defaultAsyncAssertion: UInt64 = 3_000_000_000
}

@MainActor
func waitUntil(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return condition()
}

@MainActor
func staysTrue(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.shortStabilityWindow,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if !condition() {
            return false
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return condition()
}

func staysTrue(
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.shortStabilityWindow,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if !(await condition()) {
            return false
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return await condition()
}

@MainActor
func drainMainActorTasks(iterations: Int = 5) async {
    for _ in 0..<max(0, iterations) {
        await Task.yield()
    }
}
