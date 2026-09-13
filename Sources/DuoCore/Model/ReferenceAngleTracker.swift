import Foundation

/// Establishes and maintains the lid's resting ("reference") angle.
///
/// Users position their display differently, so `90°` is not a usable baseline. The
/// tracker waits for the lid to sit still, records that angle, follows the lid when it
/// opens wider, and re-baselines when the lid has been parked at a new angle for a long
/// time (for example tilted down to cut glare) so the effect clears instead of sticking.
/// Holding the lid part-way for a few seconds does not re-baseline; the effect freezes.
public struct ReferenceAngleTracker: Equatable {
    public struct Configuration: Equatable {
        /// Readings within this many degrees of the anchor count as "still".
        public var stableTolerance: Double
        /// How long the lid must be still before the first reference is taken.
        public var initialStableDuration: TimeInterval
        /// How long the lid must be still at a lower angle before re-baselining.
        public var rebaselineAfter: TimeInterval
        /// Never re-baseline below this angle (that is a closing lid, not a new rest pose).
        public var minimumRebaselineAngle: Double

        public init(
            stableTolerance: Double = 1.5,
            initialStableDuration: TimeInterval = 0.75,
            rebaselineAfter: TimeInterval = 20,
            minimumRebaselineAngle: Double = 30
        ) {
            self.stableTolerance = stableTolerance
            self.initialStableDuration = initialStableDuration
            self.rebaselineAfter = rebaselineAfter
            self.minimumRebaselineAngle = minimumRebaselineAngle
        }
    }

    public var configuration: Configuration
    public private(set) var reference: Double?
    private var stableAnchor: Double?
    private var stableSince: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Seconds the lid has been still, or `nil` before the first reading.
    public func stableDuration(at time: TimeInterval) -> TimeInterval? {
        guard let since = stableSince else { return nil }
        return time - since
    }

    /// Feeds a reading and returns the current reference angle, if one exists yet.
    @discardableResult
    public mutating func update(angle: Double, time: TimeInterval) -> Double? {
        if let anchor = stableAnchor, abs(angle - anchor) <= configuration.stableTolerance {
            // Still within the stable band; keep the anchor.
        } else {
            stableAnchor = angle
            stableSince = time
        }
        let stableFor = time - (stableSince ?? time)

        guard let current = reference else {
            if stableFor >= configuration.initialStableDuration {
                reference = angle
            }
            return reference
        }

        if angle > current {
            // Opened wider than before: that is the new rest position, no effect wanted here.
            reference = angle
        } else if stableFor >= configuration.rebaselineAfter,
                  angle >= configuration.minimumRebaselineAngle,
                  angle < current {
            reference = angle
        }
        return reference
    }

    /// Explicit calibration from the UI.
    public mutating func calibrate(to angle: Double, time: TimeInterval) {
        reference = angle
        stableAnchor = angle
        stableSince = time
    }
}
