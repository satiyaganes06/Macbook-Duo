import XCTest
@testable import DuoCore

final class FoldGeometryTests: XCTestCase {
    func testZeroTiltIsIdentity() {
        let g = FoldGeometry(tilt: 0)
        for (x, y) in [(-0.8, 0.0), (0.8, 0.0), (-0.8, 1.0), (0.8, 1.0), (0.3, 0.5)] {
            let p = g.project(x: x, y: y)
            XCTAssertEqual(p.x, x, accuracy: 1e-12)
            XCTAssertEqual(p.y, y, accuracy: 1e-12)
            XCTAssertEqual(p.w, 1, accuracy: 1e-12)
        }
    }

    func testHingeRowIsFixedForEveryTilt() {
        for degrees in stride(from: 0.0, through: 80.0, by: 5.0) {
            let g = FoldGeometry(tilt: degrees * .pi / 180)
            for x in [-0.8, -0.2, 0.0, 0.5, 0.8] {
                let p = g.project(x: x, y: 0)
                XCTAssertEqual(p.x, x, accuracy: 1e-12, "hinge x drifted at \(degrees)°")
                XCTAssertEqual(p.y, 0, accuracy: 1e-12, "hinge y drifted at \(degrees)°")
            }
        }
    }

    func testTopEdgeExpandsMonotonicallyWithTilt() {
        var previousWidth = 0.0
        for degrees in stride(from: 0.0, through: 70.0, by: 2.0) {
            let g = FoldGeometry(tilt: degrees * .pi / 180)
            let right = g.project(x: 0.8, y: 1)
            XCTAssertGreaterThanOrEqual(right.x, previousWidth - 1e-12, "expansion reversed at \(degrees)°")
            XCTAssertLessThanOrEqual(right.w, 1, "top edge should move toward the viewer")
            previousWidth = right.x
        }
        XCTAssertGreaterThan(previousWidth, 0.8 * 1.5, "70° should expand the top edge well past 1.5x")
    }

    func testTopEdgeStaysAboveHingeUpToMaxTilt() {
        let viewDistance = 1.8
        let viewerHeight = 0.45
        let limit = FoldGeometry.maxTilt(viewDistance: viewDistance, viewerHeight: viewerHeight)
        XCTAssertGreaterThan(limit, 60 * .pi / 180)
        XCTAssertLessThan(limit, 89 * .pi / 180)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let g = FoldGeometry(tilt: limit * fraction, viewDistance: viewDistance, viewerHeight: viewerHeight)
            let top = g.project(x: 0, y: 1)
            XCTAssertGreaterThan(top.y, 0, "top folded through the hinge at \(fraction * 100)% of max tilt")
            XCTAssertGreaterThan(top.w, 0)
        }
    }

    func testNegativeTiltShrinksInsteadOfExpanding() {
        let g = FoldGeometry(tilt: -40 * .pi / 180)
        let right = g.project(x: 0.8, y: 1)
        XCTAssertLessThan(right.x, 0.8)
        XCTAssertGreaterThan(right.w, 1)
        XCTAssertLessThan(right.y, 1)
    }
}
