import XCTest
@testable import DuoCore

final class ReferenceAngleTrackerTests: XCTestCase {
    func testReferenceIsTakenOnlyAfterTheLidSitsStill() {
        var tracker = ReferenceAngleTracker()
        XCTAssertNil(tracker.update(angle: 128, time: 0))
        XCTAssertNil(tracker.update(angle: 128, time: 0.5))
        XCTAssertEqual(tracker.update(angle: 128, time: 0.8), 128)
    }

    func testMovementResetsTheStabilityClock() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 128, time: 0)
        tracker.update(angle: 120, time: 0.5)   // still moving
        XCTAssertNil(tracker.update(angle: 110, time: 1.0))
        XCTAssertNil(tracker.update(angle: 110, time: 1.5))
        XCTAssertEqual(tracker.update(angle: 110, time: 1.8), 110)
    }

    func testNoiseWithinToleranceStillCountsAsStill() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 128, time: 0)
        tracker.update(angle: 129, time: 0.3)
        tracker.update(angle: 127, time: 0.6)
        XCTAssertEqual(tracker.update(angle: 128, time: 0.8), 128)
    }

    func testOpeningWiderFollowsImmediately() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 110, time: 0)
        tracker.update(angle: 110, time: 1)
        XCTAssertEqual(tracker.update(angle: 125, time: 1.1), 125)
    }

    func testClosingDoesNotMoveTheReferenceQuickly() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 120, time: 0)
        tracker.update(angle: 120, time: 1)
        for t in stride(from: 1.1, through: 10.0, by: 0.1) {
            XCTAssertEqual(tracker.update(angle: 70, time: t), 120, "re-baselined too early at t=\(t)")
        }
    }

    func testParkedLidRebaselinesAfterTheLongDelay() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 120, time: 0)
        tracker.update(angle: 120, time: 1)
        tracker.update(angle: 95, time: 2)
        XCTAssertEqual(tracker.update(angle: 95, time: 21.9), 120)
        XCTAssertEqual(tracker.update(angle: 95, time: 22.1), 95)
    }

    func testNeverRebaselinesNearClosed() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 120, time: 0)
        tracker.update(angle: 120, time: 1)
        tracker.update(angle: 15, time: 2)
        XCTAssertEqual(tracker.update(angle: 15, time: 60), 120)
    }

    func testCalibrateOverridesEverything() {
        var tracker = ReferenceAngleTracker()
        tracker.update(angle: 120, time: 0)
        tracker.update(angle: 120, time: 1)
        tracker.calibrate(to: 100, time: 2)
        XCTAssertEqual(tracker.reference, 100)
        XCTAssertEqual(tracker.update(angle: 100, time: 2.1), 100)
    }
}
