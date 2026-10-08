import Foundation
package struct RebuildPresentationState {
    private var waiterCountByConfigId: [UUID: Int] = [:]

    var rebuildingConfigIds: Set<UUID> { Set(waiterCountByConfigId.keys) }
    private(set) var rebuildFailureMessageByConfigId: [UUID: String] = [:]
    private(set) var recentlyAppliedConfigIds: Set<UUID> = []

    mutating func beginRebuild(configId: UUID) {
        let count = waiterCountByConfigId[configId, default: 0]
        waiterCountByConfigId[configId] = count + 1
        if count == 0 {
            rebuildFailureMessageByConfigId.removeValue(forKey: configId)
            recentlyAppliedConfigIds.remove(configId)
        }
    }

    mutating func finishRebuild(configId: UUID) {
        let count = waiterCountByConfigId[configId, default: 0]
        waiterCountByConfigId[configId] = count > 1 ? count - 1 : nil
    }

    mutating func markRebuildSuccess(configId: UUID) {
        rebuildFailureMessageByConfigId.removeValue(forKey: configId)
        recentlyAppliedConfigIds.insert(configId)
    }

    mutating func markRebuildFailure(configId: UUID, message: String) {
        rebuildFailureMessageByConfigId[configId] = message
        recentlyAppliedConfigIds.remove(configId)
    }

    mutating func clearRecentApply(configId: UUID) {
        recentlyAppliedConfigIds.remove(configId)
    }

    mutating func clear(configId: UUID) {
        waiterCountByConfigId[configId] = nil
        rebuildFailureMessageByConfigId.removeValue(forKey: configId)
        recentlyAppliedConfigIds.remove(configId)
    }

    package func allConfigIds(extra: Set<UUID> = []) -> Set<UUID> {
        extra
            .union(rebuildingConfigIds)
            .union(Set(rebuildFailureMessageByConfigId.keys))
            .union(recentlyAppliedConfigIds)
    }
}
