import AppKit
import CoreGraphics
import SwiftUI

package struct CapturePreviewSurface: View {
    let hasSession: Bool
    let renderer: ZeroCopyPreviewRenderer
    let scaleMode: CapturePreviewScaleMode
    let nativeFrameSizeInPoints: CGSize

    package var body: some View {
        if hasSession {
            if renderer.hasReceivedFrame {
                if scaleMode == .fit {
                    ZeroCopyPreviewLayerView(renderer: renderer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        ZeroCopyPreviewLayerView(renderer: renderer)
                            .frame(
                                width: nativeFrameSizeInPoints.width,
                                height: nativeFrameSizeInPoints.height
                            )
                            .background(Color.black)
                    }
                    .background(TransparentCapturePreviewScrollView())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Loading...")
                    .foregroundStyle(.white.opacity(0.85))
            }
        } else {
            Text("No Data")
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct TransparentCapturePreviewScrollView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            configure(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            configure(from: nsView)
        }
    }

    @MainActor
    private func configure(from view: NSView) {
        guard let scrollView = sequence(first: view.superview, next: { $0?.superview })
            .first(where: { $0 is NSScrollView }) as? NSScrollView
        else { return }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
    }
}
