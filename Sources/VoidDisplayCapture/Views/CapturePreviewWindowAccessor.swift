import AppKit
import SwiftUI

package struct CapturePreviewWindowAccessor: NSViewRepresentable {
    private let onResolve: (NSWindow) -> Void

    package init(onResolve: @escaping (NSWindow) -> Void) {
        self.onResolve = onResolve
    }

    package func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveWindow(for: view)
        return view
    }

    package func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(for: nsView)
    }

    private func resolveWindow(for view: NSView) {
        Task { @MainActor in
            if let window = view.window {
                onResolve(window)
            }
        }
    }
}
