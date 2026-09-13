import Foundation

/// Turns normalized progress / lid movement into the individual render parameters.
/// Every curve is hand-tuned rather than linear so the effect starts subtle and
/// finishes decisively near the closed position.
public struct EffectCurves: Equatable {
    /// Viewer distance from the screen, in pane heights. Larger = gentler expansion.
    public var viewDistance: Double
    /// Viewer eye height, in pane heights (0.5 = centered on the screen).
    public var viewerHeight: Double
    /// Highest blur pyramid level the compositor may sample (the renderer builds 4).
    public var maxBlurLevel: Double
    public var blurExponent: Double
    /// Progress at which dimming starts / reaches black.
    public var dimStart: Double
    public var dimEnd: Double
    /// `+1` rotates the top edge toward the viewer (expand, the Duo look); `-1` away.
    public var tiltDirection: Double

    public init(
        viewDistance: Double = 1.8,
        viewerHeight: Double = 0.45,
        maxBlurLevel: Double = 4,
        blurExponent: Double = 1.3,
        dimStart: Double = 0.35,
        dimEnd: Double = 0.9,
        tiltDirection: Double = 1
    ) {
        self.viewDistance = viewDistance
        self.viewerHeight = viewerHeight
        self.maxBlurLevel = maxBlurLevel
        self.blurExponent = blurExponent
        self.dimStart = dimStart
        self.dimEnd = dimEnd
        self.tiltDirection = tiltDirection
    }

    public var maxTiltRadians: Double {
        FoldGeometry.maxTilt(viewDistance: viewDistance, viewerHeight: viewerHeight)
    }

    /// The pane follows the lid one-to-one until the projection limit, so small lid
    /// movements produce small visual movements.
    public func tiltRadians(effectiveMovementDegrees degrees: Double) -> Double {
        let radians = max(0, degrees) * .pi / 180
        return min(radians, maxTiltRadians) * tiltDirection
    }

    public func blurLevel(progress: Double) -> Double {
        pow(clamp01(progress), blurExponent) * maxBlurLevel
    }

    public func brightness(progress: Double) -> Double {
        1 - smoothstep(dimStart, dimEnd, progress)
    }

    /// Per-style blur. The mechanical styles stay sharp; Duo softens, Iris softens a little.
    public func blurLevel(progress: Double, style: EffectStyle) -> Double {
        switch style {
        case .duo: return blurLevel(progress: progress)
        case .iris: return clamp01(progress) * clamp01(progress) * 2
        case .shutter, .roll, .accordion, .fade: return 0
        }
    }

    /// Per-style dimming. Every style ends black so the display sleeps on a blank overlay.
    public func brightness(progress: Double, style: EffectStyle) -> Double {
        switch style {
        case .duo: return brightness(progress: progress)
        case .shutter, .accordion: return 1 - smoothstep(0.8, 1, progress)
        case .iris: return 1 - smoothstep(0.75, 1, progress)
        case .roll: return 1 - smoothstep(0.85, 1, progress)
        case .fade: return 1 - fadeOpacity(progress: progress)
        }
    }

    /// Opacity of the plain black overlay used for Reduce Motion / the Fade style.
    public func fadeOpacity(progress: Double) -> Double {
        smoothstep(0, 1, progress)
    }
}

@inline(__always)
func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}
