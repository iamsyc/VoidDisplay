import VoidDisplayFoundation
import Foundation
package nonisolated enum SnapshotRefreshReason: String, Codable, Equatable, Sendable {
    case startup
    case eventRecorded = "event_recorded"
    case captureStateChanged = "capture_state_changed"
    case sharingStateChanged = "sharing_state_changed"
    case virtualDisplayStateChanged = "virtual_display_state_changed"
    case screenCatalogStateChanged = "screen_catalog_state_changed"
    case displayRuntimeTransactionChanged = "display_runtime_transaction_changed"
    case manualDiagnosticsRefresh = "manual_diagnostics_refresh"
    case exportRequested = "export_requested"
}
