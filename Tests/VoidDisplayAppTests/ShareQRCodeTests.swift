@testable import VoidDisplayApp
import CoreImage
import Foundation
import Testing

@MainActor
struct ShareQRCodeTests {
    @Test func generatedCodeDecodesToTheExactCapabilityURL() throws {
        let url = try #require(URL(string: "http://192.0.2.1:8089/display/123/test-only-capability"))
        let image = try #require(ShareQRCode.image(for: url))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try #require(detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)
        #expect(feature.messageString == url.absoluteString)
        #expect(image.width == image.height)
    }
}
