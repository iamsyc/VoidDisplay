@testable import VoidDisplayFoundation
@testable import VoidDisplayVirtualDisplay
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct CreateVirtualDisplayWorkflowTests {
    @Test func submitSendsSingleRuntimeBackedRequestAndSucceeds() async {
        var requests: [VirtualDisplayCreateRequest] = []
        let workflow = CreateVirtualDisplayWorkflow { request in
            requests.append(request)
            return UUID()
        }

        let outcome = await workflow.submit(
            displayName: "Workflow Display",
            serialNumber: 9501,
            physicalSize: (width: 600, height: 340),
            maxPixelDimensions: .resolved(width: 1920, height: 1080),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
        )

        #expect(outcome == .created)
        #expect(requests.count == 1)
        #expect(requests.first?.displayName == "Workflow Display")
        #expect(requests.first?.serialNumber == 9501)
        #expect(requests.first?.maximumPixelWidth == 1920)
        #expect(requests.first?.maximumPixelHeight == 1080)
    }

    @Test func submitFailureReturnsFailedAfterSingleCreateRequest() async {
        var requestCount = 0
        let workflow = CreateVirtualDisplayWorkflow { _ in
            requestCount += 1
            throw NSError(domain: "CreateVirtualDisplayWorkflowTests", code: 1)
        }

        let outcome = await workflow.submit(
            displayName: "Workflow Failure",
            serialNumber: 9502,
            physicalSize: (width: 600, height: 340),
            maxPixelDimensions: .resolved(width: 1920, height: 1080),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
        )

        #expect(outcome == .failed)
        #expect(requestCount == 1)
    }

    @Test func invalidResolutionDoesNotEnterRuntimeRequest() async {
        var requestCount = 0
        let workflow = CreateVirtualDisplayWorkflow { _ in
            requestCount += 1
            return UUID()
        }

        let outcome = await workflow.submit(
            displayName: "Invalid",
            serialNumber: 9503,
            physicalSize: (width: 600, height: 340),
            maxPixelDimensions: .invalidValues,
            modes: []
        )

        #expect(outcome == .invalidResolution)
        #expect(requestCount == 0)
    }
}
