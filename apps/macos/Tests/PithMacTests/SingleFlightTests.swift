import PithMacCore
import XCTest

@MainActor
final class SingleFlightTests: XCTestCase {
    private final class Gate {
        var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { waiting.append($0) }
        }
        func openOne() {
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
    }

    private func spin(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
    }

    func testRequestsDuringARunCollapseIntoOneRunWithTheNewestInput() async {
        let gate = Gate()
        var performed: [Int] = []
        let flight = SingleFlight<Int> { input in
            performed.append(input)
            await gate.wait()
        }

        let first = flight.submit(1)
        await spin { gate.waiting.count == 1 }
        XCTAssertEqual(performed, [1])

        let second = flight.submit(2)
        let third = flight.submit(3)
        XCTAssertTrue(flight.hasPending)
        gate.openOne()
        await spin { gate.waiting.count == 1 }
        XCTAssertEqual(performed, [1, 3])
        gate.openOne()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(performed, [1, 3])
        XCTAssertFalse(flight.hasPending)
    }

    func testAnIdleFlightStartsFreshForTheNextRequest() async {
        var performed: [Int] = []
        let flight = SingleFlight<Int> { performed.append($0) }
        await flight.submit(1).value
        await flight.submit(2).value
        await flight.settled()
        XCTAssertEqual(performed, [1, 2])
    }
}
