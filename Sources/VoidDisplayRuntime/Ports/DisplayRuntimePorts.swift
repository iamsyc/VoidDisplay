@MainActor
package protocol DisplayRuntimeCatalogProviding {
    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot
}

@MainActor
package protocol DisplayRuntimeCaptureProviding {
    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot
}

@MainActor
package protocol DisplayRuntimeSharingProviding {
    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot
}

@MainActor
package protocol DisplayRuntimeVirtualDisplayProviding {
    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot
}
