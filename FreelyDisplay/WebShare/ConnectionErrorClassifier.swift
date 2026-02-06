import Foundation
import Network

func shouldTreatAsExpectedClientDisconnect(_ error: Error) -> Bool {
    if let nwError = error as? NWError {
        return isExpectedClientDisconnect(nwError)
    }
    if let posixError = error as? POSIXError {
        return isExpectedClientDisconnect(posixError.code)
    }

    let nsError = error as NSError
    guard nsError.domain == NSPOSIXErrorDomain,
          let code = POSIXErrorCode(rawValue: Int32(nsError.code)) else {
        return false
    }
    return isExpectedClientDisconnect(code)
}

private func isExpectedClientDisconnect(_ nwError: NWError) -> Bool {
    switch nwError {
    case .posix(let code):
        return isExpectedClientDisconnect(code)
    default:
        return false
    }
}

private func isExpectedClientDisconnect(_ code: POSIXErrorCode) -> Bool {
    switch code {
    case .ECONNRESET, .EPIPE, .ECANCELED:
        return true
    default:
        return false
    }
}
