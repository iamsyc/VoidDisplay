@testable import VoidDisplayApp
import Testing

@MainActor
struct HomeCopyShareAddressFeedbackStateTests {
    @Test func newerConfirmationSupersedesPendingHide() {
        var state = HomeCopyShareAddressFeedbackState()
        let firstRevision = state.beginConfirmation()
        let secondRevision = state.beginConfirmation()

        state.endConfirmation(ifCurrent: firstRevision)

        #expect(state.isShowingConfirmation)
        #expect(state.revision == secondRevision)
    }

    @Test func currentConfirmationCanEnd() {
        var state = HomeCopyShareAddressFeedbackState()
        let revision = state.beginConfirmation()

        state.endConfirmation(ifCurrent: revision)

        #expect(!state.isShowingConfirmation)
    }

    @Test func addressChangeInvalidatesPendingConfirmation() {
        var state = HomeCopyShareAddressFeedbackState()
        let staleRevision = state.beginConfirmation()

        state.cancelConfirmation()

        #expect(!state.isShowingConfirmation)

        let currentRevision = state.beginConfirmation()
        state.endConfirmation(ifCurrent: staleRevision)

        #expect(state.isShowingConfirmation)
        #expect(state.revision == currentRevision)
    }
}
