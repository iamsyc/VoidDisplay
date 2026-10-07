import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

package enum SharingConnectionText {
    package static func status(_ count: Int) -> String {
        count == 0 ? String(localized: "Waiting for connections") : String(localized: "\(count) active connections")
    }
}

package enum ShareQRCode {
    package static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: .white).cropped(to: extent)
        let scale = max(1, floor(256 / extent.width))
        let image = code.composited(over: white).transformed(by: .init(scaleX: scale, y: scale))
        return CIContext().createCGImage(image, from: image.extent)
    }
}

package struct ShareSessionView: View {
    package let configID: UUID
    @Environment(\.openURL) private var openURL
    @State private var controller: HomeVirtualDisplaySurfaceController
    @State private var address: String?
    @State private var isStopping = false
    @State private var showsGuide = false
    @State private var copied = false
    private let sharingAdapter: DisplayRuntimeSharingAdapter
    private let displayRuntime: DisplayRuntime

    package init(
        configID: UUID, capture: CaptureController, sharing: SharingController,
        virtualDisplay: VirtualDisplayController, capturePerformancePreferences: CapturePerformancePreferences,
        displayRuntime: DisplayRuntime, sharingAdapter: DisplayRuntimeSharingAdapter
    ) {
        self.configID = configID
        self.displayRuntime = displayRuntime
        self.sharingAdapter = sharingAdapter
        _controller = State(initialValue: HomeVirtualDisplaySurfaceController(
            capture: capture, sharing: sharing, virtualDisplay: virtualDisplay,
            capturePerformancePreferences: capturePerformancePreferences,
            displayRuntime: displayRuntime, sharingAdapter: sharingAdapter
        ))
    }

    private var item: HomeVirtualDisplayItemPresentation? {
        controller.presentation.items.first { $0.id == configID }
    }

    private var isStarting: Bool {
        item.map { controller.itemRenderStates(for: [$0]).first?.isWebViewStarting == true } ?? false
    }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item?.title ?? String(localized: "Virtual Display")).font(.title2.bold())
                if let item, item.isSharing, !isStopping {
                    HStack {
                        Text(SharingConnectionText.status(item.viewerCount)).accessibilityIdentifier("sharing_connection_status")
                        Spacer()
                        Button("Stop Sharing", role: .destructive) {
                            guard let displayID = item.displayID else { return }
                            isStopping = true
                            address = nil
                            Task {
                                await sharingAdapter.stopLANWebViewSharing(displayID: displayID, runtime: displayRuntime)
                                isStopping = false
                            }
                        }
                        .accessibilityIdentifier("sharing_stop_button")
                    }
                    Text("Open this link on a supported device on the same trusted local network.")
                        .foregroundStyle(.secondary)
                    if let address, let url = URL(string: address) {
                        if let image = ShareQRCode.image(for: url) {
                            Image(decorative: image, scale: 1)
                                .interpolation(.none)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(Text("Scan to open the sharing link"))
                        } else {
                            Text("The QR code could not be generated. Copy the link instead.")
                        }
                        Text(address).font(.callout.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("sharing_access_address")
                        HStack {
                            Button(copied ? String(localized: "Copied") : String(localized: "Copy Access Link")) {
                                refreshAddress()
                                guard let address = self.address else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                                copied = true
                            }
                            Button("Open on This Mac") {
                                refreshAddress()
                                if let address = self.address, let url = URL(string: address) { openURL(url) }
                            }
                        }
                    } else {
                        Text("No local network address is available. Check your network, then refresh the address.")
                    }
                    Button("Refresh Address", action: refreshAddress)
                    Text("Playback requires H.265 Main Level 6 support. If playback fails, check the receiving browser’s message or try another supported device.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Each browser tab counts as a connection. Check playback on the receiving device.")
                        .font(.caption).foregroundStyle(.secondary)

                } else if isStarting {
                    ProgressView("Preparing")
                } else {
                    Text(isStopping ? String(localized: "Stopping Sharing…") : String(localized: "Sharing has stopped. The previous link is no longer valid."))
                    if let item, item.isRunning, !isStopping {
                        Button("Start sharing") {
                            controller.perform(.webView, for: item, openPreviewWindow: { _ in }, openSharePage: { _ in }, editConfig: { _ in })
                        }
                    }
                }
                if let alert = controller.actionAlert { Text(alert.message).foregroundStyle(.red) }
                DisclosureGroup("Put content on this display", isExpanded: $showsGuide) {
                    DisplayContentGuideView(displayName: item?.title ?? String(localized: "Virtual Display"))
                }
                Text("Closing this window keeps sharing active. Use Stop Sharing to end the session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 420, minHeight: 500)
        .accessibilityIdentifier("sharing_session_window")
        .onChange(of: item?.shareAddress, initial: true) { _, newValue in
            address = isStopping ? nil : newValue
            copied = false
        }
        .onAppear(perform: refreshAddress)
    }

    private func refreshAddress() {
        address = isStopping ? nil : item?.shareAddress
        copied = false
    }
}
