import AppKit
@testable import PithMacApp
import XCTest

final class PreviewAnchorTests: XCTestCase {
    private let firstLine = NSRect(x: 200, y: 0, width: 130, height: 24)
    private let secondLine = NSRect(x: 0, y: 24, width: 80, height: 24)

    func testAWrappedLinkAnchorsToThePieceUnderThePointer() {
        let pieces = [firstLine, secondLine]
        XCTAssertEqual(PithTextView.linePiece(containing: NSPoint(x: 250, y: 10), in: pieces), firstLine)
        XCTAssertEqual(PithTextView.linePiece(containing: NSPoint(x: 40, y: 30), in: pieces), secondLine)
    }

    func testAPointerJustOutsideFallsBackToTheNearestLine() {
        let pieces = [firstLine, secondLine]
        XCTAssertEqual(PithTextView.linePiece(containing: NSPoint(x: 40, y: 52), in: pieces), secondLine)
        XCTAssertNil(PithTextView.linePiece(containing: .zero, in: []))
    }
}
