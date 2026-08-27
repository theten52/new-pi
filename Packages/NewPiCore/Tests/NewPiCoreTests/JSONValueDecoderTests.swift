import Foundation
import Testing
@testable import NewPiCore

struct JSONValueDecoderTests {
    @Test func numericZeroAndOneAreIntegersNotBooleans() throws {
        let value = try JSONValueDecoder.decode(from: #"{"zero":0,"one":1,"truthy":true,"half":0.5}"#)
        #expect(value.objectValue?["zero"] == .int(0))
        #expect(value.objectValue?["one"] == .int(1))
        #expect(value.objectValue?["truthy"] == .bool(true))
        #expect(value.objectValue?["half"] == .double(0.5))
    }

    @Test func negativeAndLargeIntegersStayIntegers() throws {
        let value = try JSONValueDecoder.decode(from: #"{"neg":-1,"big":9223372036854775807}"#)
        #expect(value.objectValue?["neg"] == .int(-1))
        #expect(value.objectValue?["big"] == .int(Int.max))
    }

    @Test func booleansInArraysRemainBooleans() throws {
        let value = try JSONValueDecoder.decode(from: #"[true,false,0,1]"#)
        guard case let .array(items) = value else {
            Issue.record("Expected array, got \(value)")
            return
        }
        let expected: [JSONValue] = [.bool(true), .bool(false), .int(0), .int(1)]
        #expect(items == expected)
    }
}
