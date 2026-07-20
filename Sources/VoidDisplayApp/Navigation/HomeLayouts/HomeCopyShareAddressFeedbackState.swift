struct HomeCopyShareAddressFeedbackState {
    private(set) var isShowingConfirmation = false
    private(set) var revision: UInt64 = 0

    @discardableResult
    mutating func beginConfirmation() -> UInt64 {
        revision &+= 1
        isShowingConfirmation = true
        return revision
    }

    mutating func endConfirmation(ifCurrent candidateRevision: UInt64) {
        guard candidateRevision == revision else { return }
        isShowingConfirmation = false
    }

    mutating func cancelConfirmation() {
        revision &+= 1
        isShowingConfirmation = false
    }
}
