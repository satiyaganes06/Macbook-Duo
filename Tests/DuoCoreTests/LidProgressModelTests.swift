import XCTest
@testable import DuoCore

final class LidProgressModelTests: XCTestCase {
    let model = LidProgressModel()

    func testRestAndDeadZoneProduceNoEffect() {
        XCTAssertEqual(model.progress(reference: 110, angle: 110), 0)
        XCTAssertEqual(model.progress(reference: 110, angle: 112), 0, "opening wider is never an effect")
        XCTAssertEqual(model.progress(reference: 110, angle: 108), 0, "inside the dead zone")
        XCTAssertEqual(model.effectiveMovement(reference: 110, angle: 108), 0)
    }

    func testClosedAngleIsFullProgress() {
        XCTAssertEqual(model.progress(reference: 110, angle: model.closedAngle), 1, accuracy: 1e-12)
        XCTAssertEqual(model.progress(reference: 110, angle: 0), 1, accuracy: 1e-12)
    }

    func testProgressIsMonotonicWhileClosing() {
        var previous = -1.0
        for angle in stride(from: 110.0, through: 0.0, by: -1.0) {
            let p = model.progress(reference: 110, angle: angle)
            XCTAssertGreaterThanOrEqual(p, previous, "progress dropped at \(angle)°")
            XCTAssertLessThanOrEqual(p, 1)
            previous = p
        }
    }

    func testSmallMovementsProduceSmallChanges() {
        let a = model.progress(reference: 110, angle: 100)
        let b = model.progress(reference: 110, angle: 99)
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThan(b - a, 0.03)
    }

    func testEaseOutFrontLoadsTheEffect() {
        // Reference 110: 25° of movement should already be around a third of the way.
        let p = model.progress(reference: 110, angle: 85)
        XCTAssertGreaterThan(p, 0.28)
        XCTAssertLessThan(p, 0.42)
        // And 60° of movement should be around three quarters.
        let q = model.progress(reference: 110, angle: 50)
        XCTAssertGreaterThan(q, 0.68)
        XCTAssertLessThan(q, 0.82)
    }

    func testDifferentRestingAnglesNormalizeTheSameWay() {
        // Half of the effective span should give the same progress regardless of rest angle.
        for reference in [95.0, 110.0, 130.0] {
            let half = model.span(reference: reference) / 2
            let p = model.progress(effectiveMovement: half, reference: reference)
            XCTAssertEqual(p, model.ease(0.5), accuracy: 1e-12)
        }
    }
}
