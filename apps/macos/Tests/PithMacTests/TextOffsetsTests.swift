import Foundation
import PithMacCore
import XCTest

final class TextOffsetsTests: XCTestCase {
    private let text = "👍🏽 cargo"

    func testLengthCountsUnicodeScalarsLikeTheCore() {
        XCTAssertEqual(TextOffsets.length(text), 8)
        XCTAssertEqual(text.count, 7)
    }

    func testScalarOffsetsMapToTextViewPositions() {
        XCTAssertEqual(TextOffsets.utf16(fromScalar: 3, in: text), 5)
        XCTAssertEqual(TextOffsets.scalar(fromUTF16: 5, in: text), 3)
    }

    func testAPositionInsideASurrogatePairRoundsDown() {
        XCTAssertEqual(TextOffsets.scalar(fromUTF16: 1, in: text), 0)
    }

    func testSplitAtAScalarOffset() {
        let (before, after) = TextOffsets.split(text, atScalar: 3)
        XCTAssertEqual(before, "👍🏽 ")
        XCTAssertEqual(after, "cargo")
    }

    func testOffsetsAreClampedToTheText() {
        XCTAssertEqual(TextOffsets.utf16(fromScalar: 99, in: "ab"), 2)
        XCTAssertEqual(TextOffsets.split("ab", atScalar: -4).before, "")
    }
}
