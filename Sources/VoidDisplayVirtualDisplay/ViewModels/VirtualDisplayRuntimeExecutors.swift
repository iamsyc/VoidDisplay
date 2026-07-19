import Foundation

package typealias VirtualDisplayRebuildExecutor = @MainActor (
    UUID,
    VirtualDisplayRebuildRequestSource
) async throws -> Void

package typealias VirtualDisplayDesiredEnabledExecutor = @MainActor (
    UUID,
    Bool,
    VirtualDisplayDesiredEnabledRequestSource
) async throws -> Void

package typealias VirtualDisplayEditRebuildExecutor = @MainActor (
    VirtualDisplayConfig,
    String,
    VirtualDisplayRebuildRequestSource
) async throws -> VirtualDisplayEditRebuildOperation

package typealias VirtualDisplayCreateExecutor = @MainActor (
    VirtualDisplayCreateRequest
) async throws -> UUID

package typealias VirtualDisplayDeleteExecutor = @MainActor (
    UUID
) async throws -> Void

package struct VirtualDisplayRuntimeExecutors {
    package let rebuild: VirtualDisplayRebuildExecutor
    package let setDesiredEnabled: VirtualDisplayDesiredEnabledExecutor
    package let editAndRebuild: VirtualDisplayEditRebuildExecutor
    package let create: VirtualDisplayCreateExecutor
    package let delete: VirtualDisplayDeleteExecutor

    package init(
        rebuild: @escaping VirtualDisplayRebuildExecutor,
        setDesiredEnabled: @escaping VirtualDisplayDesiredEnabledExecutor,
        editAndRebuild: @escaping VirtualDisplayEditRebuildExecutor,
        create: @escaping VirtualDisplayCreateExecutor,
        delete: @escaping VirtualDisplayDeleteExecutor
    ) {
        self.rebuild = rebuild
        self.setDesiredEnabled = setDesiredEnabled
        self.editAndRebuild = editAndRebuild
        self.create = create
        self.delete = delete
    }
}
