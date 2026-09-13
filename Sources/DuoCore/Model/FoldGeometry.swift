import Foundation

/// CPU mirror of the projective geometry used by `foldVertex` in `Shaders.metal`.
///
/// The desktop is a rigid pane whose bottom edge is the hinge. Coordinates are in
/// units of pane height: `y ∈ [0, 1]` with the hinge at `y = 0`, and `x` in the same
/// units (so a 16:10 pane spans `x ∈ [-0.8, 0.8]`). A stationary viewer sits in front
/// of the physical screen at `(0, viewerHeight, viewDistance)` looking along `-z`.
///
/// Rotating the pane about the hinge by `tilt` moves points off the screen plane; the
/// viewer's line of sight through each rotated point is intersected with the physical
/// screen plane (`z = 0`), which is what gets drawn. Positive tilt brings the top edge
/// toward the viewer, so the pane expands and its top edge slides toward the hinge.
/// The hinge row (`y = 0`) is a fixed point of the mapping for every tilt.
public struct FoldGeometry: Equatable {
    public var tilt: Double
    public var viewDistance: Double
    public var viewerHeight: Double

    public init(tilt: Double, viewDistance: Double = 1.8, viewerHeight: Double = 0.45) {
        self.tilt = tilt
        self.viewDistance = viewDistance
        self.viewerHeight = viewerHeight
    }

    public struct Projected: Equatable {
        /// Point on the physical screen plane, same units as the input.
        public var x: Double
        public var y: Double
        /// Homogeneous divisor. `< 1` means the point moved toward the viewer (expansion).
        public var w: Double
    }

    /// Projects a pane point onto the physical screen plane.
    public func project(x: Double, y: Double) -> Projected {
        let y3 = y * cos(tilt)
        let z3 = y * sin(tilt)
        let w = max(1 - z3 / viewDistance, 1e-3)
        let px = x / w
        let py = viewerHeight + (y3 - viewerHeight) / w
        return Projected(x: px, y: py, w: w)
    }

    /// Largest positive tilt (radians) for which the top edge of the pane stays above the
    /// hinge on screen. Beyond this the projection folds over on itself, so the effect
    /// clamps tilt here and lets dimming finish the job.
    public static func maxTilt(viewDistance: Double, viewerHeight: Double) -> Double {
        guard viewerHeight > 0 else { return 88 * .pi / 180 }
        let limit = atan(viewDistance / viewerHeight) - 3 * .pi / 180
        return min(limit, 88 * .pi / 180)
    }
}
