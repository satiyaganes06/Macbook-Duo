import XCTest
@testable import DuoCore

final class CriticallyDampedFilterTests: XCTestCase {
    func testConvergesToTargetWithoutOvershoot() {
        var filter = CriticallyDampedFilter(omega: 32, initial: 0)
        filter.target = 40
        var previous = 0.0
        for _ in 0..<120 {   // 2 s at 60 Hz
            let v = filter.step(dt: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-9, "value moved away from target")
            XCTAssertLessThanOrEqual(v, 40 + 1e-9, "overshoot")
            previous = v
        }
        XCTAssertEqual(filter.value, 40, accuracy: 1e-6)
        XCTAssertEqual(filter.velocity, 0, accuracy: 1e-6)
    }

    func testSettlesWithinRoughlyFourTimeConstants() {
        var filter = CriticallyDampedFilter(omega: 32, initial: 0)
        filter.target = 10
        let settle = 4.0 / 32.0
        var elapsed = 0.0
        while elapsed < settle {
            filter.step(dt: 1.0 / 120.0)
            elapsed += 1.0 / 120.0
        }
        XCTAssertGreaterThan(filter.value, 9.0, "should be >90% of the way after 4/omega seconds")
    }

    func testReversalDoesNotOvershootWhenTargetFlips() {
        var filter = CriticallyDampedFilter(omega: 32, initial: 0)
        filter.target = 30
        for _ in 0..<6 { filter.step(dt: 1.0 / 60.0) }   // build up velocity
        XCTAssertGreaterThan(filter.velocity, 0)
        filter.target = 0
        for _ in 0..<120 {
            let v = filter.step(dt: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(v, -1e-9, "crossed below the new target")
        }
        XCTAssertEqual(filter.value, 0, accuracy: 1e-6)
    }

    func testFollowsAMovingTargetClosely() {
        // Lid closing at 60°/s reported in whole degrees at 60 Hz.
        var filter = CriticallyDampedFilter(omega: 32, initial: 0)
        var lag = 0.0
        for i in 1...60 {
            filter.target = Double(i)
            filter.step(dt: 1.0 / 60.0)
            lag = max(lag, filter.target - filter.value)
        }
        XCTAssertLessThan(lag, 4.5, "visual should trail the lid by only a few degrees")
    }

    func testLargeTimeStepIsStable() {
        var filter = CriticallyDampedFilter(omega: 32, initial: 0)
        filter.target = 50
        let v = filter.step(dt: 1.0)
        XCTAssertEqual(v, 50, accuracy: 1e-6)
        XCTAssertFalse(v.isNaN)
    }
}
