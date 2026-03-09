import SwiftUI
import AppKit
import CoreGraphics

struct ShareDisplayMetaBar: View {
    let displayID: CGDirectDisplayID
    let displayAddress: String?
    let displayURL: URL?
    let displayClientCount: Int
    let isSharingDisplay: Bool
    let openURLAction: OpenURLAction

    var body: some View {
        HStack(spacing: AppUI.Spacing.small + 2) {
            if let displayAddress {
                addressGroup(displayAddress)

                separator
            }

            viewersGroup
        }
        .padding(.vertical, AppUI.Spacing.xSmall + 1)
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
    }

    private func addressGroup(_ displayAddress: String) -> some View {
        HStack(spacing: AppUI.Spacing.small) {
            Button(
                String(localized: "Open Share Page"),
                systemImage: "link",
                action: openSharePage
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(isSharingDisplay ? Color.accentColor : .secondary)
            .disabled(displayURL == nil || !isSharingDisplay)
            .help(String(localized: "Open Share Page"))

            Text(displayAddress)
                .font(.footnote.monospaced())
                .foregroundStyle(isSharingDisplay ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("share_display_address_\(displayID)")

            Button(
                String(localized: "Copy display address"),
                systemImage: "doc.on.doc",
                action: copyAddress
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var viewersGroup: some View {
        Label {
            Text("\(displayClientCount)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        } icon: {
            Image(systemName: "person.2")
                .font(.footnote.weight(.medium))
        }
        .foregroundStyle(displayClientCount > 0 ? Color.accentColor : .secondary)
        .accessibilityLabel(connectedClientsAccessibilityLabel(displayClientCount))
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: AppUI.Stroke.subtle, height: 14)
            .accessibilityHidden(true)
    }

    private func openSharePage() {
        guard isSharingDisplay, let displayURL else { return }
        openURLAction(displayURL)
    }

    private func copyAddress() {
        guard let displayAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayAddress, forType: .string)
    }

    private func connectedClientsAccessibilityLabel(_ count: Int) -> String {
        let format = String(localized: "%lld connected")
        return String.localizedStringWithFormat(format, Int64(count))
    }
}
