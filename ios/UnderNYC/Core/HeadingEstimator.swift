import Foundation

enum HeadingSource: String, Sendable {
    case none
    case calibration
    case magnetometer
    case gpsCourse
}

struct HeadingEstimate: Equatable, Sendable {
    var worldYawOffsetDegrees: Double?
    var cameraHeadingDegrees: Double?
    var standardDeviationDegrees: Double
    var source: HeadingSource
    var timestamp: TimeInterval

    /// A finite north reference is enough to keep the AR scene running. The
    /// uncertainty is presented to the user separately instead of turning a
    /// noisy-but-useful compass reading into a full-screen failure state.
    var hasReference: Bool {
        guard let worldYawOffsetDegrees, let cameraHeadingDegrees else {
            return false
        }
        return worldYawOffsetDegrees.isFinite
            && cameraHeadingDegrees.isFinite
            && standardDeviationDegrees.isFinite
    }

    var isUsable: Bool {
        hasReference
            && standardDeviationDegrees
                <= HeadingEstimator.preciseStandardDeviationDegrees
    }

    var isPrecise: Bool {
        hasReference
            && standardDeviationDegrees
                <= HeadingEstimator.preciseStandardDeviationDegrees
    }

    static let unavailable = HeadingEstimate(
        worldYawOffsetDegrees: nil,
        cameraHeadingDegrees: nil,
        standardDeviationDegrees: .infinity,
        source: .none,
        timestamp: 0
    )
}

enum HeadingCalibrationState: Equatable, Sendable {
    case idle
    case collecting(progress: Double, coverageDegrees: Double, validSamples: Int)
    case ready
    case failed(String)
}

struct HeadingCalibrationSample: Equatable, Sendable {
    let timestamp: TimeInterval
    let arCameraBearingDegrees: Double
    let absoluteCameraHeadingDegrees: Double
    let measurementStandardDeviationDegrees: Double
    let magneticFieldMicrotesla: Double?
    let magneticQualityIsUsable: Bool
}

struct HeadingEstimator: Sendable {
    static let calibrationDurationSeconds = 5.0
    static let minimumCalibrationSamples = 30
    static let minimumCalibrationCoverageDegrees = 220.0
    static let preciseStandardDeviationDegrees = 8.0

    private(set) var calibrationState: HeadingCalibrationState = .idle
    private(set) var estimate: HeadingEstimate = .unavailable

    private var calibrationStartedAt: TimeInterval?
    private var samples: [HeadingCalibrationSample] = []
    private var offsetVarianceDegreesSquared = Double.infinity
    private var lastPredictionTimestamp: TimeInterval?
    private var consecutiveRejectedUpdates = 0

    /// Fast startup from the phone's current absolute heading. ARKit supplies
    /// the stable relative frame; Core Location supplies the one-time yaw
    /// offset and its reported uncertainty. This avoids requiring a forced
    /// 220-degree rotation before anything can render.
    @discardableResult
    mutating func initializeAbsoluteHeading(
        arCameraBearingDegrees: Double,
        absoluteCameraHeadingDegrees: Double,
        measurementStandardDeviationDegrees: Double,
        timestamp: TimeInterval
    ) -> Bool {
        guard arCameraBearingDegrees.isFinite,
              absoluteCameraHeadingDegrees.isFinite,
              measurementStandardDeviationDegrees.isFinite,
              measurementStandardDeviationDegrees > 0,
              measurementStandardDeviationDegrees
                <= Self.preciseStandardDeviationDegrees
        else { return false }
        let sigma = max(3, measurementStandardDeviationDegrees)
        let offset = Self.normalizeDegrees(
            absoluteCameraHeadingDegrees - arCameraBearingDegrees
        )
        offsetVarianceDegreesSquared = sigma * sigma
        estimate = HeadingEstimate(
            worldYawOffsetDegrees: offset,
            cameraHeadingDegrees: Self.normalizeDegrees(
                arCameraBearingDegrees + offset
            ),
            standardDeviationDegrees: sigma,
            source: .magnetometer,
            timestamp: timestamp
        )
        calibrationStartedAt = nil
        samples.removeAll(keepingCapacity: true)
        lastPredictionTimestamp = timestamp
        consecutiveRejectedUpdates = 0
        calibrationState = .ready
        return true
    }

    mutating func startCalibration(at timestamp: TimeInterval) {
        calibrationStartedAt = timestamp
        samples.removeAll(keepingCapacity: true)
        estimate = .unavailable
        offsetVarianceDegreesSquared = .infinity
        lastPredictionTimestamp = timestamp
        consecutiveRejectedUpdates = 0
        calibrationState = .collecting(
            progress: 0,
            coverageDegrees: 0,
            validSamples: 0
        )
    }

    mutating func addCalibrationSample(_ sample: HeadingCalibrationSample) {
        guard let startedAt = calibrationStartedAt else { return }
        guard sample.timestamp >= startedAt,
              sample.measurementStandardDeviationDegrees.isFinite,
              sample.measurementStandardDeviationDegrees > 0,
              sample.measurementStandardDeviationDegrees <= 25,
              sample.magneticQualityIsUsable,
              magneticMagnitudeIsPlausible(sample.magneticFieldMicrotesla)
        else {
            updateCalibrationProgress(at: sample.timestamp)
            if sample.timestamp - startedAt >= Self.calibrationDurationSeconds {
                finishCalibration(at: sample.timestamp)
            }
            return
        }
        samples.append(sample)
        updateCalibrationProgress(at: sample.timestamp)
        if sample.timestamp - startedAt >= Self.calibrationDurationSeconds {
            finishCalibration(at: sample.timestamp)
        }
    }

    mutating func advanceCalibrationClock(to timestamp: TimeInterval) {
        guard let startedAt = calibrationStartedAt else { return }
        updateCalibrationProgress(at: timestamp)
        if timestamp - startedAt >= Self.calibrationDurationSeconds {
            finishCalibration(at: timestamp)
        }
    }

    mutating func finishCalibration(at timestamp: TimeInterval) {
        guard calibrationStartedAt != nil else { return }
        let coverage = angularCoverageDegrees(samples.map(\.arCameraBearingDegrees))
        guard samples.count >= Self.minimumCalibrationSamples else {
            calibrationState = .failed("Not enough valid heading samples; rotate again away from metal.")
            return
        }
        guard coverage >= Self.minimumCalibrationCoverageDegrees else {
            calibrationState = .failed("Rotate the phone farther around you, then retry.")
            return
        }

        let offsets = samples.map {
            Self.signedDeltaDegrees(
                from: $0.arCameraBearingDegrees,
                to: $0.absoluteCameraHeadingDegrees
            )
        }
        let mean = circularMeanDegrees(offsets)
        let residuals = offsets.map { Self.signedDeltaDegrees(from: mean, to: $0) }
        let reportedAccuracy = samples
            .map(\.measurementStandardDeviationDegrees)
            .sorted()[samples.count / 2]
        let robustSigma = max(
            1.5,
            robustStandardDeviation(residuals),
            reportedAccuracy
        )
        guard robustSigma <= 12 else {
            calibrationState = .failed("Indoor magnetic readings are inconsistent; move away from steel and retry.")
            return
        }

        offsetVarianceDegreesSquared = robustSigma * robustSigma
        estimate = HeadingEstimate(
            worldYawOffsetDegrees: Self.normalizeDegrees(mean),
            cameraHeadingDegrees: nil,
            standardDeviationDegrees: robustSigma,
            source: .calibration,
            timestamp: timestamp
        )
        lastPredictionTimestamp = timestamp
        calibrationState = .ready
    }

    mutating func predict(arCameraBearingDegrees: Double, at timestamp: TimeInterval) {
        guard let offset = estimate.worldYawOffsetDegrees else { return }
        if let previous = lastPredictionTimestamp {
            let elapsed = max(0, min(timestamp - previous, 2))
            offsetVarianceDegreesSquared += elapsed * 0.12
        }
        lastPredictionTimestamp = timestamp
        estimate.cameraHeadingDegrees = Self.normalizeDegrees(
            arCameraBearingDegrees + offset
        )
        estimate.standardDeviationDegrees = sqrt(offsetVarianceDegreesSquared)
        estimate.timestamp = timestamp
    }

    mutating func updateAbsoluteHeading(
        arCameraBearingDegrees: Double,
        absoluteCameraHeadingDegrees: Double,
        measurementStandardDeviationDegrees: Double,
        source: HeadingSource,
        timestamp: TimeInterval
    ) -> Bool {
        guard let priorOffset = estimate.worldYawOffsetDegrees,
              measurementStandardDeviationDegrees.isFinite,
              measurementStandardDeviationDegrees > 0
        else { return false }
        predict(arCameraBearingDegrees: arCameraBearingDegrees, at: timestamp)
        let measuredOffset = Self.normalizeDegrees(
            absoluteCameraHeadingDegrees - arCameraBearingDegrees
        )
        let innovation = Self.signedDeltaDegrees(from: priorOffset, to: measuredOffset)
        let measurementVariance = measurementStandardDeviationDegrees
            * measurementStandardDeviationDegrees
        let innovationVariance = offsetVarianceDegreesSquared + measurementVariance
        guard innovation * innovation / max(innovationVariance, 0.001) <= 9 else {
            consecutiveRejectedUpdates += 1
            return false
        }

        let gain = offsetVarianceDegreesSquared / max(innovationVariance, 0.001)
        let updatedOffset = Self.normalizeDegrees(priorOffset + gain * innovation)
        offsetVarianceDegreesSquared = max(
            1,
            (1 - gain) * offsetVarianceDegreesSquared
        )
        estimate = HeadingEstimate(
            worldYawOffsetDegrees: updatedOffset,
            cameraHeadingDegrees: Self.normalizeDegrees(
                arCameraBearingDegrees + updatedOffset
            ),
            standardDeviationDegrees: sqrt(offsetVarianceDegreesSquared),
            source: source,
            timestamp: timestamp
        )
        consecutiveRejectedUpdates = 0
        return true
    }

    mutating func invalidate(reason: String) {
        estimate = .unavailable
        calibrationState = .failed(reason)
        calibrationStartedAt = nil
        samples.removeAll(keepingCapacity: true)
        offsetVarianceDegreesSquared = .infinity
    }

    static func normalizeDegrees(_ degrees: Double) -> Double {
        let result = degrees.truncatingRemainder(dividingBy: 360)
        return result >= 0 ? result : result + 360
    }

    static func signedDeltaDegrees(from start: Double, to end: Double) -> Double {
        var delta = normalizeDegrees(end) - normalizeDegrees(start)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private mutating func updateCalibrationProgress(at timestamp: TimeInterval) {
        guard let startedAt = calibrationStartedAt else { return }
        let progress = min(
            max((timestamp - startedAt) / Self.calibrationDurationSeconds, 0),
            1
        )
        calibrationState = .collecting(
            progress: progress,
            coverageDegrees: angularCoverageDegrees(samples.map(\.arCameraBearingDegrees)),
            validSamples: samples.count
        )
    }

    private func angularCoverageDegrees(_ angles: [Double]) -> Double {
        guard angles.count >= 2 else { return 0 }
        let sorted = angles.map(Self.normalizeDegrees).sorted()
        var largestGap = 0.0
        for (first, second) in zip(sorted, sorted.dropFirst()) {
            largestGap = max(largestGap, second - first)
        }
        largestGap = max(largestGap, sorted[0] + 360 - sorted[sorted.count - 1])
        return 360 - largestGap
    }

    private func circularMeanDegrees(_ angles: [Double]) -> Double {
        let radians = angles.map { $0 * .pi / 180 }
        let sine = radians.reduce(0) { $0 + sin($1) }
        let cosine = radians.reduce(0) { $0 + cos($1) }
        return Self.normalizeDegrees(atan2(sine, cosine) * 180 / .pi)
    }

    private func robustStandardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let median = values.sorted()[values.count / 2]
        let deviations = values.map { abs($0 - median) }.sorted()
        return max(1, deviations[deviations.count / 2] * 1.4826)
    }

    private func magneticMagnitudeIsPlausible(_ magnitude: Double?) -> Bool {
        guard let magnitude else { return true }
        return (20...90).contains(magnitude)
    }
}
