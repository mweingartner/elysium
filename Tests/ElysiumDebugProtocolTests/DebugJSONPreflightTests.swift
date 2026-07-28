import Foundation
import XCTest
@testable import ElysiumDebugProtocol

final class DebugJSONPreflightTests: XCTestCase {
    func testAcceptsBoundedRequestShape() throws {
        try DebugJSONPreflight.validate(Data(#"{"operation":"player.teleport","arguments":{"x":1e2,"y":64,"z":-1E-2},"flags":[true,false,null]}"#.utf8))
    }

    func testRejectsDuplicateAndEscapeEquivalentKeys() {
        XCTAssertThrowsError(try DebugJSONPreflight.validate(Data(#"{"a":1,"a":2}"#.utf8)))
        XCTAssertThrowsError(try DebugJSONPreflight.validate(Data(#"{"a":1,"\u0061":2}"#.utf8)))
    }

    func testRejectsDepthMemberAndStringLimits() {
        XCTAssertThrowsError(try DebugJSONPreflight.validate(
            Data(#"{"a":{"b":{"c":1}}}"#.utf8), maximumDepth: 2))
        XCTAssertThrowsError(try DebugJSONPreflight.validate(
            Data(#"{"a":1,"b":2}"#.utf8), maximumObjectMembers: 1))
        XCTAssertThrowsError(try DebugJSONPreflight.validate(
            Data(#"{"a":"12345"}"#.utf8), maximumStringBytes: 4))
    }

    func testRejectsMalformedNumbersAndTrailingData() {
        for value in [#"{"n":01}"#, #"{"n":1.}"#, #"{"n":1e}"#, "1e", "1E+", #"{}{}"#] {
            XCTAssertThrowsError(try DebugJSONPreflight.validate(Data(value.utf8)))
        }
    }

    func testTopLevelNumbersAndTrailingWhitespaceAreBoundsSafe() throws {
        for value in ["1", "1e2", "1E-2", "0\n", "-12.5\t"] {
            try DebugJSONPreflight.validate(Data(value.utf8))
        }
    }
}
