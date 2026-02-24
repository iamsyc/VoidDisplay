import AppKit
import SwiftUI
import Testing
@testable import VoidDisplay

@Suite(.serialized)
@MainActor
struct VirtualDisplayRowTests {
    private static let appBootstrap: Void = {
        _ = NSApplication.shared
    }()

    @Test func rowBodyEvaluatesWhenRunning() {
        let row = makeRow(
            isRunning: true,
            isRebuilding: false,
            rebuildFailureMessage: nil
        )
        render(row)
    }

    @Test func rowBodyEvaluatesWhenRebuilding() {
        let row = makeRow(
            isRunning: true,
            isRebuilding: true,
            rebuildFailureMessage: nil
        )
        render(row)
    }

    @Test func rowBodyEvaluatesWhenRetryIsVisible() {
        let row = makeRow(
            isRunning: false,
            isRebuilding: false,
            rebuildFailureMessage: "Topology repair failed"
        )
        render(row)
    }

    private func makeRow(
        isRunning: Bool,
        isRebuilding: Bool,
        rebuildFailureMessage: String?
    ) -> VirtualDisplayRow {
        let config = VirtualDisplayConfig(
            name: "Managed Display",
            serialNum: 42,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )

        return VirtualDisplayRow(
            config: config,
            isRunning: isRunning,
            isToggling: false,
            isRebuilding: isRebuilding,
            rebuildFailureMessage: rebuildFailureMessage,
            hasRecentApplySuccess: false,
            isFirst: false,
            isLast: false,
            isPrimary: false,
            onMoveUp: {},
            onMoveDown: {},
            onToggle: {},
            onEdit: {},
            onDelete: {},
            onRetryRebuild: {}
        )
    }

    private func render<V: View>(_ view: V) {
        _ = Self.appBootstrap
        autoreleasepool {
            let host = NSHostingController(rootView: view)
            host.view.layoutSubtreeIfNeeded()
        }
    }
}
