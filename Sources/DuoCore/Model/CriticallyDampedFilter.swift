import Foundation

/// Critically damped second-order smoother.
///
/// The lid sensor reports whole degrees at an irregular rate, so rendering the raw
/// value directly stutters. This filter eases toward the target with no overshoot and
/// no ringing, and it uses the closed-form solution per step so it is stable for any
/// frame interval. `omega` (rad/s) sets the response: settle time is roughly `4 / omega`.
public struct CriticallyDampedFilter: Equatable {
    public var omega: Double
    public var target: Double
    public private(set) var value: Double
    public private(set) var velocity: Double
    /// Below this distance the value snaps to the target so the effect can settle exactly.
    public var snapDistance: Double

    public init(omega: Double = 32, initial: Double = 0, snapDistance: Double = 0.01) {
        self.omega = omega
        self.target = initial
        self.value = initial
        self.velocity = 0
        self.snapDistance = snapDistance
    }

    public mutating func reset(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }

    /// Advances the filter by `dt` seconds and returns the new value.
    @discardableResult
    public mutating func step(dt: Double) -> Double {
        guard dt > 0 else { return value }
        let x0 = value - target
        let v0 = velocity
        if abs(x0) <= snapDistance && abs(v0) < snapDistance * omega {
            value = target
            velocity = 0
            return value
        }
        let e = exp(-omega * dt)
        let k = v0 + omega * x0
        var x = (x0 + k * dt) * e
        var v = (v0 - omega * k * dt) * e
        // A critically damped system never overshoots from rest, but carried velocity can
        // push it across the target. Clamp so the visual never crosses the physical lid.
        if (x0 > 0 && x < 0) || (x0 < 0 && x > 0) {
            x = 0
            v = 0
        }
        value = target + x
        velocity = v
        return value
    }
}
