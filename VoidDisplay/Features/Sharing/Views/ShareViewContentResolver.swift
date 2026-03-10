import Foundation

@MainActor
enum ShareViewContentState: Equatable {
    case permissionGuide
    case permissionLoading
    case serviceStopped
    case displaysList
    case displaysLoading
    case empty
}

@MainActor
enum ShareViewContentResolver {
    static func resolve(
        catalog: ScreenCaptureDisplayCatalogState,
        isWebServiceRunning: Bool,
        visibleDisplayCount: Int
    ) -> ShareViewContentState {
        if catalog.hasScreenCapturePermission == false {
            return .permissionGuide
        }
        if catalog.hasScreenCapturePermission == nil {
            return .permissionLoading
        }
        if !isWebServiceRunning {
            return .serviceStopped
        }
        if catalog.displays != nil {
            return visibleDisplayCount > 0 ? .displaysList : .empty
        }
        if catalog.isLoadingDisplays {
            return .displaysLoading
        }
        return .empty
    }
}
