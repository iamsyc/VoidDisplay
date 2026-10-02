import Foundation
import Observation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

@MainActor @Observable
package final class DisplaySceneController {
    package let store: DisplaySceneStore
    package let runtime: DisplayRuntime
    private let virtualDisplay: VirtualDisplayController
    package private(set) var lastResult: DisplayRuntimeEnabledSetResult?
    package var errorMessage: String?
    private var isApplying = false

    package init(store: DisplaySceneStore, runtime: DisplayRuntime, virtualDisplay: VirtualDisplayController) {
        self.store = store
        self.runtime = runtime
        self.virtualDisplay = virtualDisplay
    }

    package var configs: [VirtualDisplayConfig] { virtualDisplay.displayConfigs }
    package var isBusy: Bool { isApplying || !runtime.makeSnapshot().transactions.activeTransactions.isEmpty }
    package var desiredConfigIDs: [UUID] { runtime.makeSnapshot().virtualDisplay.configs.filter(\.desiredEnabled).map(\.id) }
    package var currentCombinationIsSettled: Bool {
        !isBusy && Set(desiredConfigIDs) == Set(runtime.makeSnapshot().virtualDisplay.runningConfigIDs)
    }
    package var matchedScene: DisplayScene? {
        guard !store.hasLoadFailure, currentCombinationIsSettled else { return nil }
        return store.scenes.first { !hasMissingReferences($0) && Set($0.enabledConfigIDs) == Set(desiredConfigIDs) }
    }
    package func hasMissingReferences(_ scene: DisplayScene) -> Bool {
        !Set(scene.enabledConfigIDs).isSubset(of: Set(configs.map(\.id)))
    }
    package func sceneNames(referencing configID: UUID) -> [String] {
        store.scenes.filter { $0.enabledConfigIDs.contains(configID) }.map(\.name)
    }
    package func name(for configID: UUID) -> String {
        configs.first { $0.id == configID }?.displayName ?? String(localized: "Missing Display")
    }

    package func select(_ scene: DisplayScene) -> DisplayRuntimeEnabledSetPlan? {
        request(targetConfigIDs: scene.enabledConfigIDs)
    }

    package func request(targetConfigIDs: [UUID]) -> DisplayRuntimeEnabledSetPlan? {
        guard !isBusy else { return nil }
        errorMessage = nil
        do {
            let plan = try runtime.prepareVirtualDisplayEnabledSet(targetConfigIDs: targetConfigIDs)
            guard !plan.steps.isEmpty else { return nil }
            if plan.steps.contains(where: { !$0.enabled }) || !plan.interruptedConfigIDs.isEmpty {
                return plan
            } else {
                apply(plan)
            }
        } catch {
            present(error)
        }
        return nil
    }

    package func apply(_ plan: DisplayRuntimeEnabledSetPlan) {
        guard !isBusy else { return }
        isApplying = true
        errorMessage = nil
        lastResult = nil
        Task {
            defer { isApplying = false }
            do {
                let result = try await runtime.applyVirtualDisplayEnabledSet(plan: plan, source: .displaySceneApply) { [virtualDisplay] in
                    virtualDisplay.refreshVirtualDisplayState()
                }
                lastResult = result
            } catch {
                present(error)
            }
        }
    }

    package func dismissResult() { lastResult = nil }

    private func present(_ error: Error) {
        switch error as? DisplayRuntimeEnabledSetError {
        case .stalePlan: errorMessage = String(localized: "The displays changed while waiting. Select the scene again to review the new changes.")
        case .missingConfiguration: errorMessage = String(localized: "This scene references a deleted display. Edit the scene before applying it.")
        case .configurationUnavailable: errorMessage = String(localized: "Resolve the display configuration load error before applying a scene.")
        case .alreadyApplying: errorMessage = String(localized: "A scene is already being applied.")
        case nil: errorMessage = error.localizedDescription
        }
    }
}
