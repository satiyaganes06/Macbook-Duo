import Foundation

/// Maps a physical lid angle to a normalized effect progress in `[0, 1]`.
///
/// - `reference` is the resting (open) angle established by `ReferenceAngleTracker`.
/// - `closedAngle` is where the effect must be fully complete (black). It sits a little
///   above the physical closed switch so macOS sleeps the display on a blank overlay.
/// - `deadZone` ignores small wobbles around the resting angle.
///
/// The mapping is ease-out: the first degrees of closing produce a comparatively larger
/// change than the last ones, which matches how the reference effect feels.
public struct LidProgressModel: Equatable {
    public var closedAngle: Double
    public var deadZone: Double
    public var easeExponent: Double

    public init(closedAngle: Double = 12, deadZone: Double = 2.5, easeExponent: Double = 1.6) {
        self.closedAngle = closedAngle
        self.deadZone = deadZone
        self.easeExponent = easeExponent
    }

    /// Degrees the lid moved from rest toward closed. Never negative.
    public func rawMovement(reference: Double, angle: Double) -> Double {
        max(0, reference - angle)
    }

    /// Movement beyond the dead zone. This is what drives tilt and progress. Never negative.
    public func effectiveMovement(reference: Double, angle: Double) -> Double {
        max(0, reference - angle - deadZone)
    }

    /// Effective movement needed to reach `closedAngle`.
    public func span(reference: Double) -> Double {
        max(1, reference - closedAngle - deadZone)
    }

    public func rawProgress(effectiveMovement: Double, reference: Double) -> Double {
        min(1, max(0, effectiveMovement / span(reference: reference)))
    }

    public func progress(effectiveMovement: Double, reference: Double) -> Double {
        ease(rawProgress(effectiveMovement: effectiveMovement, reference: reference))
    }

    public func progress(reference: Double, angle: Double) -> Double {
        progress(effectiveMovement: effectiveMovement(reference: reference, angle: angle), reference: reference)
    }

    /// Ease-out curve: `1 - (1 - raw)^k`.
    public func ease(_ raw: Double) -> Double {
        let r = min(1, max(0, raw))
        return 1 - pow(1 - r, easeExponent)
    }
}
