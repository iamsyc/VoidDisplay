import SwiftUI
import VoidDisplayRuntime

private struct SceneConfirmation: Identifiable {
    let plan: DisplayRuntimeEnabledSetPlan
    var id: UUID { plan.operationID.rawValue }
}

package struct DisplaySceneControls: View {
    @Environment(DisplaySceneController.self) private var controller
    package var compact = false
    @State private var showsManager = false
    @State private var confirmation: SceneConfirmation?

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(controller.store.scenes) { scene in
                        Button {
                            confirm(controller.select(scene))
                        } label: {
                            Label(scene.name, systemImage: controller.hasMissingReferences(scene) ? "exclamationmark.triangle" : "display.2")
                        }
                        .disabled(controller.isBusy || controller.store.hasLoadFailure)
                    }
                    Divider()
                    Button("Manage Scenes") { showsManager = true }
                } label: {
                    Label(controller.matchedScene?.name ?? String(localized: "Custom Combination"), systemImage: "display.2")
                        .lineLimit(1)
                }
                .accessibilityIdentifier("display_scene_menu")
                if !compact {
                    Spacer()
                    Button("Save Current Combination") { showsManager = true }
                        .disabled(controller.isBusy || controller.store.hasLoadFailure)
                        .accessibilityIdentifier("display_scene_save_current_button")
                }
            }
            if let progress = controller.runtime.makeSnapshot().enabledSetApplication {
                ProgressView(value: Double(progress.completedStepCount), total: Double(max(1, progress.totalStepCount))) {
                    Text("Applying scene: \(progress.completedStepCount) of \(progress.totalStepCount)")
                }
            }
            if controller.store.hasLoadFailure {
                Text("Scenes could not be loaded. Reload or reset the scenes file before saving.").font(.caption).foregroundStyle(.red)
            }
            if let message = controller.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            if let result = controller.lastResult {
                Text(result.status == .completed ? String(localized: "Display combination applied.") : String(localized: "The combination was only partly applied. Completed changes have been kept."))
                    .font(.callout)
                DisclosureGroup("Change Results") {
                    ForEach(result.steps, id: \.step.configID) { step in
                        HStack {
                            Text(controller.name(for: step.step.configID))
                            Spacer()
                            Text(step.result.status == .completed ? String(localized: "Completed") : String(localized: "Failed"))
                        }
                    }
                    ForEach(result.skippedSteps, id: \.configID) { step in
                        Text("Not attempted: \(controller.name(for: step.configID))")
                    }
                }
                if result.status == .completedWithRecoveryFailures {
                    Text("Retry failed previews or sharing from the display row.").font(.caption)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { resultActions(result) }
                    VStack(alignment: .leading) { resultActions(result) }
                }
                .controlSize(.small)
                .disabled(controller.isBusy)
            }
        }
        .sheet(isPresented: $showsManager) { DisplaySceneManagerView().environment(controller) }
        .sheet(item: $confirmation) { value in
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Display Changes").font(.title2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(value.plan.steps, id: \.configID) { step in
                            Label(controller.name(for: step.configID), systemImage: step.enabled ? "play.fill" : "stop.fill")
                            Text(step.enabled ? String(localized: "Will enable") : String(localized: "Will disable and end its preview and sharing"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !value.plan.interruptedConfigIDs.isEmpty {
                            Text("Existing previews and sharing may briefly stop while displays change.")
                            ForEach(value.plan.interruptedConfigIDs, id: \.self) { id in
                                Text(controller.name(for: id)).font(.callout)
                            }
                        }
                    }
                }
                HStack {
                    Button("Cancel") { confirmation = nil }
                    Spacer()
                    Button("Apply Scene") {
                        confirmation = nil
                        controller.apply(value.plan)
                    }
                    .disabled(controller.isBusy)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("display_scene_confirm_button")
                }
            }
            .padding(24).frame(width: 460, height: 460)
        }
    }

    @ViewBuilder
    private func resultActions(_ result: DisplayRuntimeEnabledSetResult) -> some View {
        if result.status != .completed, Set(controller.desiredConfigIDs) != Set(result.targetConfigIDs)
            || Set(controller.runtime.makeSnapshot().virtualDisplay.runningConfigIDs) != Set(result.targetConfigIDs) {
            Button("Retry Remaining Changes") { confirm(controller.request(targetConfigIDs: result.targetConfigIDs)) }
        }
        Button("Restore Previous Combination") { confirm(controller.request(targetConfigIDs: result.previousConfigIDs)) }
        Button("Close", action: controller.dismissResult)
    }

    private func confirm(_ plan: DisplayRuntimeEnabledSetPlan?) {
        confirmation = plan.map { SceneConfirmation(plan: $0) }
    }
}
