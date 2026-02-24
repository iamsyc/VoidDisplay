//
//  AppSettingsView.swift
//  VoidDisplay
//

import SwiftUI

struct AppSettingsView: View {
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @State private var showResetConfirmation = false
    @State private var resetCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Virtual Displays")
                .font(.headline)

            Text("Reset will remove all saved virtual display configurations and stop currently managed virtual displays.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Reset Virtual Display Configurations", role: .destructive) {
                showResetConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            if resetCompleted {
                Text("Reset completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .frame(width: 420, height: 170, alignment: .topLeading)
        .confirmationDialog(
            "Reset Virtual Display Configurations?",
            isPresented: $showResetConfirmation
        ) {
            Button("Reset", role: .destructive) {
                _ = virtualDisplay.resetVirtualDisplayData()
                resetCompleted = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}
