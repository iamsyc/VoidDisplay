@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
import Foundation
import Testing

struct ObservabilitySanitizerTests {
    @Test(arguments: ["token", "secret", "password", "capability"])
    func zeroWidthSpaceRemainsInsideCredential(key: String) throws {
        let credential = "synthetic-head\u{200B}private-suffix"
        let input = "\(key)=\(credential) state=ready"
        #expect(input.contains("private-suffix"))
        let sanitizer = ObservabilitySanitizer()
        let output = try #require(sanitizer.sanitize(text: input))

        #expect(output == "\(key)=\"<redacted-token>\" state=ready")
        #expect(output.contains("private-suffix") == false)
        #expect(sanitizer.sanitize(text: output) == output)
    }

    @Test(arguments: [
        "{\"password\":\"\u{0301}synthetic secret\",\"state\":\"ready\"}",
        #"{"password":"synthetic 😀 \\\" value","state":"ready"}"#,
        #"{"password":{"nested":"synthetic value"},"state":"ready"}"#,
        #"{"password":["synthetic",{"nested":"value"}],"state":"ready"}"#
    ])
    func JSONCredentialsPreserveAdjacentStructure(_ input: String) throws {
        #expect(input.contains("synthetic"))
        _ = try JSONSerialization.jsonObject(with: Data(input.utf8))
        let sanitizer = ObservabilitySanitizer()
        let output = try #require(sanitizer.sanitize(text: input))
        let fields = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        #expect(fields == ["password": "<redacted-token>", "state": "ready"])
        #expect(sanitizer.sanitize(text: output) == output)
    }

    @Test(arguments: ["password=synthetic-head}tail", "token=synthetic-head]tail",
                      #"password="synthetic"tail"#, "token='synthetic'tail",
                      #"password="synthetic"}tail"#, "token='synthetic']tail",
                      #"password="synthetic with spaces"tail"#])
    func bareCredentialBracketsDoNotLeakSuffixes(_ input: String) throws {
        #expect(input.contains("tail"))
        let output = try #require(ObservabilitySanitizer().sanitize(text: input + " state=ready"))
        #expect(output.contains("synthetic-head") == false)
        #expect(output.contains("tail") == false)
        #expect(output.contains("<redacted-token>"))
        #expect(output.contains("state=ready"))
    }

    @Test(arguments: [
        #"{"password":"synthetic-value","state":"ready"}"#,
        #"Failed request: {"nested":{"secret":"synthetic-value with spaces"},"state":"ready"}"#,
        #"{"token":"synthetic-value\"quoted\\suffix","state":"ready"}"#,
        #"{'capability': 'synthetic-value with spaces', 'state': 'ready'}"#,
        #"password="synthetic-value with spaces" state=ready"#
    ])
    func quotedCredentialsAreRedactedWithoutRemovingAdjacentText(_ input: String) throws {
        #expect(input.contains("synthetic-value"))
        let output = try #require(ObservabilitySanitizer().sanitize(text: input))
        #expect(output.contains("synthetic-value") == false)
        #expect(output.contains("with spaces") == false)
        #expect(output.contains("quoted") == false)
        #expect(output.contains("<redacted-token>"))
        #expect(output.contains("ready"))
    }

    @Test func sanitizeTextRedactsHomePathsAndLocalIPs() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let input = "Open /Users/tester/Library/Logs via http://192.168.1.11:8080/display."

        let sanitized = sanitizer.sanitize(text: input)

        #expect(sanitized == "Open ~/Library/Logs via http://<redacted-ip>:8080/display.")
    }

    @Test func sanitizeMetadataAppliesValueRedaction() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let metadata = [
            "path": "/Users/tester/Documents/debug.json",
            "address": "10.0.0.8"
        ]

        let sanitized = sanitizer.sanitize(metadata: metadata)

        #expect(sanitized["path"] == "~/Documents/debug.json")
        #expect(sanitized["address"] == "<redacted-ip>")
    }

    @Test func sanitizeFileURLRewritesHomeDirectoryPrefix() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let url = URL(fileURLWithPath: "/Users/tester/Library/Application Support/VoidDisplay/support-bundle.zip")

        let sanitized = sanitizer.sanitize(fileURL: url)

        #expect(sanitized == "~/Library/Application Support/VoidDisplay/support-bundle.zip")
    }

    @Test func sanitizeTextRedactsIPv6AndAccessSecrets() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let accessToken = String(repeating: "a", count: 64)
        let input = "Connect to http://[fe80::1234]:8080/display/\(accessToken) with Bearer private-token-123 and capability=raw-secret."

        let sanitized = sanitizer.sanitize(text: input)

        #expect(sanitized?.contains("fe80::1234") == false)
        #expect(sanitized?.contains(accessToken) == false)
        #expect(sanitized?.contains("private-token-123") == false)
        #expect(sanitized?.contains("raw-secret") == false)
        #expect(sanitized?.contains("<redacted-ip>") == true)
        #expect(sanitized?.contains("<redacted-token>") == true)
    }

    @Test func sanitizeTextRedactsColonSecretsAndCredentialHeaders() {
        let sanitizer = ObservabilitySanitizer()
        let input = "token: short-secret Authorization: Basic dXNlcjpwYXNz Cookie: session=private-value"

        let sanitized = sanitizer.sanitize(text: input)

        #expect(sanitized?.contains("short-secret") == false)
        #expect(sanitized?.contains("dXNlcjpwYXNz") == false)
        #expect(sanitized?.contains("private-value") == false)
        #expect(sanitized?.contains("<redacted-token>") == true)
    }

    @Test func sanitizeMetadataRedactsSensitiveFieldsByKey() {
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let metadata = [
            "accessCapability": "short-secret",
            "displayName": "Private Screen",
            "ordinaryState": "running"
        ]

        let sanitized = sanitizer.sanitize(metadata: metadata)

        #expect(sanitized["accessCapability"] == "<redacted>")
        #expect(sanitized["displayName"] == "<redacted>")
        #expect(sanitized["ordinaryState"] == "running")
    }

    @Test func sectionSanitizerRedactsSensitiveFieldsAndSecretsInKeys() {
        let accessToken = String(repeating: "b", count: 64)
        let sanitizer = ObservabilitySanitizer(homePath: "/Users/tester")
        let sections: [String: JSONValue] = [
            "runtime": .object([
                "accessCapability": .string("short-secret"),
                "displayName": .string("Private Screen"),
                "route-\(accessToken)": .string("http://[fd00::1]:8080"),
                "latestFailure": .object([
                    "code": .string("failed http://[fd00::1]:8080/display/\(accessToken)"),
                    "sequence": .number(7)
                ])
            ])
        ]

        let sanitized = ObservabilitySectionSanitizer(sanitizer: sanitizer).sanitize(sections)
        let runtime = sanitized["runtime"]?.objectValue

        #expect(runtime?["accessCapability"] == .string("<redacted>"))
        #expect(runtime?["displayName"] == .string("<redacted>"))
        #expect(runtime?.keys.contains(where: { $0.contains(accessToken) }) == false)
        let routeValue = runtime?.first(where: { $0.key.hasPrefix("route-") })?.value.stringValue
        #expect(routeValue?.contains("fd00::1") == false)
        #expect(routeValue?.contains("<redacted-ip>") == true)
        let latestFailure = runtime?["latestFailure"]?.objectValue
        #expect(latestFailure?["sequence"]?.intValue == 7)
        #expect(latestFailure?["code"]?.stringValue?.contains(accessToken) == false)
        #expect(latestFailure?["code"]?.stringValue?.contains("fd00::1") == false)
    }

    @Test func sanitizeTextAppliesBoundedOutputAfterRedaction() {
        let sanitizer = ObservabilitySanitizer()
        let input = String(repeating: "a", count: 20_000)

        let sanitized = sanitizer.sanitize(text: input)

        #expect(sanitized?.count == 16_384)
        #expect(sanitized?.hasSuffix("…<truncated>") == true)
    }
}
