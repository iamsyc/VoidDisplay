import Foundation
import Network
import Testing
@testable import FreelyDisplay

struct ConnectionErrorClassifierTests {
    @Test func marksNWConnectionResetAsExpectedDisconnect() {
        let error = NWError.posix(.ECONNRESET)
        #expect(shouldTreatAsExpectedClientDisconnect(error))
    }

    @Test func marksPOSIXBrokenPipeAsExpectedDisconnect() {
        let error = POSIXError(.EPIPE)
        #expect(shouldTreatAsExpectedClientDisconnect(error))
    }

    @Test func marksNSErrorInPOSIXDomainAsExpectedDisconnect() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNRESET.rawValue))
        #expect(shouldTreatAsExpectedClientDisconnect(error))
    }

    @Test func marksConnectionAbortedAsExpectedDisconnect() {
        let error = POSIXError(.ECONNABORTED)
        #expect(shouldTreatAsExpectedClientDisconnect(error))
    }

    @Test func marksNotConnectedAsExpectedDisconnect() {
        let error = NWError.posix(.ENOTCONN)
        #expect(shouldTreatAsExpectedClientDisconnect(error))
    }

    @Test func keepsUnexpectedNetworkErrorAsFailure() {
        let error = NWError.posix(.ETIMEDOUT)
        #expect(shouldTreatAsExpectedClientDisconnect(error) == false)
    }
}
