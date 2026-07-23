import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import AppKit
import SwiftUI
package struct SupportBundleDraftSectionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: SupportBundleDraftFocusField?
    @AccessibilityFocusState private var isValidationMessageFocused: Bool

    @Bindable var controller: AppSettingsFeedbackController
    let validationFocusRequest: Int
    package let onExport: () -> Void

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Text(String(localized: "Describe the Issue"))
                .font(.headline)
                .accessibilityIdentifier("support_bundle_draft_section")

            if let validationMessage = controller.validationMessage {
                validationMessageView(validationMessage)
            }

            issueTypeSection

            supportField(
                title: "Issue Summary",
                description: "Summarize what went wrong, the impact, and how often it happens.",
                placeholder: "Example: The screen stays black after launch.",
                text: $controller.happened,
                lineLimit: 3...,
                minHeight: 52,
                titleIdentifier: "support_bundle_happened_title",
                descriptionIdentifier: "support_bundle_happened_description",
                fieldIdentifier: "support_bundle_happened_field",
                focusField: .happened
            )

            optionalProblemDetails

            SupportBundleContentsSection(controller: controller)

            HStack {
                Spacer(minLength: 0)
                Button(action: onExport) {
                    SupportBundleExportButtonLabel(isExporting: controller.isExporting)
                }
                .appActionButtonStyle(variant: .primary)
                .disabled(controller.isExporting)
                .accessibilityLabel(Text(exportButtonAccessibilityLabel))
                .accessibilityIdentifier("support_bundle_export_button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("support_bundle_draft_panel")
        .onChange(of: validationFocusRequest) { _, request in
            guard request > 0 else { return }
            focusedField = .happened
            isValidationMessageFocused = true
        }
        .onChange(of: controller.validationMessage) { _, message in
            if message == nil {
                isValidationMessageFocused = false
            }
        }
    }

    private var issueTypeSection: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small - 2) {
            HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Issue Type"))
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("support_bundle_issue_type_title")
                    Text(String(localized: "Choose the closest issue type."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("support_bundle_issue_type_description")
                }

                Spacer(minLength: AppUI.Spacing.small)

                issueTypePickerRow
            }

            issueTypeSelectionSummary
        }
    }

    private var issueTypePickerRow: some View {
        let presentation = controller.currentIssuePresentation

        return HStack(alignment: .center, spacing: AppUI.Spacing.small + 2) {
            Image(systemName: presentation.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Picker(
                String(localized: "Issue Type"),
                selection: $controller.issueType
            ) {
                ForEach(SupportIssueType.allCases, id: \.self) { issueType in
                    Text(String(localized: issueType.presentation.titleKey))
                        .tag(issueType)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 210, alignment: .leading)
            .disabled(controller.isExporting)
            .accessibilityIdentifier("support_bundle_issue_type_picker")
        }
    }

    private var issueTypeSelectionSummary: some View {
        let presentation = controller.currentIssuePresentation

        return VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            Text(String(localized: presentation.recommendedDiagnosticsKey))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("support_bundle_issue_type_recommendation")

            Text(String(localized: presentation.descriptionKey))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("support_bundle_issue_type_selected_description")

            Button(String(localized: "Apply Recommended Diagnostics")) {
                controller.applyRecommendedDiagnostics()
            }
            .appActionButtonStyle(variant: .default)
            .disabled(controller.isExporting || controller.usesRecommendedDiagnostics)
            .accessibilityIdentifier("support_bundle_apply_recommended_diagnostics_button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var optionalProblemDetails: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
                reproductionField
                    .frame(width: 340, alignment: .topLeading)
                expectedResultField
                    .frame(width: 340, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                reproductionField
                expectedResultField
            }
        }
    }

    private var reproductionField: some View {
        supportField(
            title: "Reproduction Steps (Optional)",
            description: "Add the steps in order when the problem can be reproduced.",
            placeholder: "Example: 1. Launch the app. 2. Open sharing. 3. Select a display.",
            text: $controller.reproductionSteps,
            lineLimit: 3...,
            minHeight: 52,
            titleIdentifier: "support_bundle_reproduction_title",
            descriptionIdentifier: "support_bundle_reproduction_description",
            fieldIdentifier: "support_bundle_reproduction_field",
            focusField: .reproductionSteps
        )
    }

    private var expectedResultField: some View {
        supportField(
            title: "Expected Result (Optional)",
            description: "Add the result you expected to see.",
            placeholder: "Example: The selected display should appear normally.",
            text: $controller.expectedResult,
            lineLimit: 3...,
            minHeight: 52,
            titleIdentifier: "support_bundle_expected_title",
            descriptionIdentifier: "support_bundle_expected_description",
            fieldIdentifier: "support_bundle_expected_field",
            focusField: .expectedResult
        )
    }

    @ViewBuilder
    private func supportField(
        title: LocalizedStringResource,
        description: LocalizedStringResource,
        placeholder: LocalizedStringResource,
        text: Binding<String>,
        lineLimit: PartialRangeFrom<Int>,
        minHeight: CGFloat,
        titleIdentifier: String,
        descriptionIdentifier: String,
        fieldIdentifier: String,
        focusField: SupportBundleDraftFocusField
    ) -> some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            Text(String(localized: title))
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier(titleIdentifier)
            Text(String(localized: description))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(descriptionIdentifier)
            TextField(
                String(localized: placeholder),
                text: text,
                axis: .vertical
            )
            .lineLimit(lineLimit)
            .focused($focusedField, equals: focusField)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(fieldBackgroundShape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                fieldBackgroundShape.stroke(
                    AppUI.Surface.cardStroke(for: colorScheme),
                    lineWidth: AppUI.Stroke.subtle
                )
            )
            .allowsHitTesting(controller.isExporting == false)
            .accessibilityIdentifier(fieldIdentifier)
        }
    }

    private var fieldBackgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
    }

    private var exportButtonAccessibilityLabel: String {
        if controller.isExporting {
            return String(localized: "Exporting Support Bundle…")
        }
        return String(localized: "Export Support Bundle")
    }

    private func validationMessageView(_ validationMessage: String) -> some View {
        Text(validationMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel(validationMessage)
            .accessibilityIdentifier("support_bundle_validation_message")
            .accessibilityFocused($isValidationMessageFocused)
            .id("support_bundle_validation_anchor")
    }
}
