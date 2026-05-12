import VoidDisplayFoundation
import Foundation
package nonisolated enum ObservabilityDomain: String, Codable, CaseIterable, Sendable {
    case general
    case capture = "capture"
    case sharing = "sharing"
    case virtualDisplay = "virtual_display"
    case screenCatalog = "screen_catalog"
    case displayRuntime = "display_runtime"
    case persistence = "persistence"
    case web = "web"
    case observability = "observability"
    case support = "support"
}
