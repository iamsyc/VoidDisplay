import SwiftUI

package struct DisplaySceneManagerView: View {
    @Environment(DisplaySceneController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var selection = Set<UUID>()
    @State private var errorMessage: String?
    @State private var confirmsReset = false

    package var body: some View {
        Form {
            if controller.store.hasLoadFailure {
                Section {
                    Text("Scenes could not be loaded. Reload or reset the scenes file before saving.")
                    Button("Reload Scenes", action: controller.store.reload)
                    Button("Reset Scenes", role: .destructive) { confirmsReset = true }
                }
            } else {
                Section("Saved Scenes") {
                    ForEach(controller.store.scenes) { scene in
                        HStack {
                            Button(scene.name) { edit(scene) }
                            if controller.hasMissingReferences(scene) {
                                Label("Needs Repair", systemImage: "exclamationmark.triangle")
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                perform { try controller.store.delete(id: scene.id) }
                                if editingID == scene.id { newScene() }
                            }
                        }
                    }
                    Button("New Scene", action: newScene)
                }
                Section {
                    TextField("Scene Name", text: $name).accessibilityIdentifier("display_scene_name_field")
                    ForEach(controller.configs) { config in
                        Toggle(config.displayName, isOn: Binding(
                            get: { selection.contains(config.id) },
                            set: { if $0 { selection.insert(config.id) } else { selection.remove(config.id) } }
                        ))
                        .accessibilityIdentifier("display_scene_config_\(config.id.uuidString)")
                    }
                    ForEach(Array(selection.subtracting(controller.configs.map(\.id))).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        Button("Remove Missing Display") { selection.remove(id) }
                    }
                    Text("Scenes use each display’s current settings. They do not save window positions, previews, or sharing sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !controller.currentCombinationIsSettled {
                        Text("The saved and running displays differ. Choose the displays to include.")
                    }
                    Button("Save Scene", action: save).disabled(controller.isBusy)
                        .accessibilityIdentifier("display_scene_save_button")
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .formStyle(.grouped).frame(width: 520, height: 560)
        .disabled(controller.isBusy)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear(perform: newScene)
        .confirmationDialog("Reset all saved scenes? Display configurations and running displays will be kept.", isPresented: $confirmsReset) {
            Button("Reset Scenes", role: .destructive) { perform { try controller.store.reset() }; newScene() }
        }
        .accessibilityIdentifier("display_scene_manager")
    }

    private func newScene() {
        editingID = nil
        var number = 1
        var proposed = String(localized: "Scene \(number)")
        while controller.store.scenes.contains(where: { $0.name.caseInsensitiveCompare(proposed) == .orderedSame }) {
            number += 1
            proposed = String(localized: "Scene \(number)")
        }
        name = proposed
        selection = Set(controller.desiredConfigIDs)
        errorMessage = nil
    }
    private func edit(_ scene: DisplayScene) {
        editingID = scene.id
        name = scene.name
        selection = Set(scene.enabledConfigIDs)
        errorMessage = nil
    }
    private func save() {
        if let duplicate = controller.store.scenes.first(where: { $0.id != editingID && Set($0.enabledConfigIDs) == selection }) {
            edit(duplicate)
            errorMessage = String(localized: "This display combination is already saved.")
            return
        }
        perform {
            editingID = try controller.store.save(id: editingID, name: name,
                enabledConfigIDs: controller.configs.map(\.id).filter(selection.contains)
                    + selection.subtracting(controller.configs.map(\.id)).sorted { $0.uuidString < $1.uuidString })
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
