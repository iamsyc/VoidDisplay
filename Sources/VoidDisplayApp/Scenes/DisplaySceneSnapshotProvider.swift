import VoidDisplayObservability

package nonisolated struct DisplaySceneDiagnostics: Codable, Sendable {
    package let sceneCount: Int
    package let invalidReferenceCount: Int
    package let storageErrorCategory: String?
}

package struct DisplaySceneSnapshotProvider: ObservabilitySnapshotProvider, @unchecked Sendable {
    package let key = "displayScenes"
    private let controller: DisplaySceneController
    package init(controller: DisplaySceneController) { self.controller = controller }
    @MainActor package func makeSnapshot() -> DisplaySceneDiagnostics {
        let known = Set(controller.configs.map(\.id))
        return .init(sceneCount: controller.store.scenes.count,
            invalidReferenceCount: controller.store.scenes.reduce(0) { $0 + Set($1.enabledConfigIDs).subtracting(known).count },
            storageErrorCategory: controller.store.errorCategory)
    }
}
