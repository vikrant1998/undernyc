import CoreLocation
import CoreMotion
import Foundation
import OSLog

@MainActor
final class HeadingFusionService: ObservableObject {
    @Published private(set) var estimate = HeadingEstimate.unavailable
    @Published private(set) var calibrationState: HeadingCalibrationState = .idle
    @Published private(set) var magneticFieldMicrotesla: Double?
    @Published private(set) var magneticQuality = "unavailable"
    @Published private(set) var relativeAltitudeMeters: Double?

    private var estimator = HeadingEstimator()
    private let logger = Logger(subsystem: "com.viksat98.UnderNYC", category: "HeadingFusion")
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var magneticQualityIsUsable = false
    private var lastMagneticUpdateTimestamp: TimeInterval?
    private var lastConsumedHeadingTimestamp: Date?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        logger.info("Starting Core Motion heading fusion")
        // Heading fusion is diagnostic now that Street mode is anchored by
        // ARGeoTracking. Fifteen hertz is ample for diagnostics and avoids a
        // needless 60 Hz sensor/filter workload beside RealityKit rendering.
        motionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let reference: CMAttitudeReferenceFrame = available.contains(.xTrueNorthZVertical)
            ? .xTrueNorthZVertical
            : .xMagneticNorthZVertical
        motionManager.startDeviceMotionUpdates(
            using: reference,
            to: .main
        ) { [weak self] motion, _ in
            guard let motion else { return }
            Task { @MainActor in self?.consume(motion) }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in
                    self?.relativeAltitudeMeters = data.relativeAltitude.doubleValue
                }
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        isStarted = false
    }

    func beginCalibration(at timestamp: TimeInterval) {
        logger.info("Beginning five-second heading calibration")
        lastConsumedHeadingTimestamp = nil
        estimator.startCalibration(at: timestamp)
        publish()
    }

    func ingestARCameraBearing(
        _ arCameraBearingDegrees: Double,
        timestamp: TimeInterval,
        heading: CLHeading?,
        location _: CLLocation?
    ) {
        if case .idle = estimator.calibrationState {
            if let heading,
               heading.headingAccuracy >= 0,
               heading.headingAccuracy
                    <= HeadingEstimator.preciseStandardDeviationDegrees,
               magneticQualityIsUsable,
               magneticSampleIsFresh(at: timestamp),
               magneticMagnitudeIsPlausible {
                let absolute = heading.trueHeading >= 0
                    ? heading.trueHeading
                    : heading.magneticHeading
                if estimator.initializeAbsoluteHeading(
                    arCameraBearingDegrees: arCameraBearingDegrees,
                    absoluteCameraHeadingDegrees: absolute,
                    measurementStandardDeviationDegrees: max(
                        heading.headingAccuracy, 3
                    ),
                    timestamp: timestamp
                ) {
                    lastConsumedHeadingTimestamp = heading.timestamp
                    logger.info("Initialized heading immediately from Core Location")
                }
            }
            publish()
            return
        }

        let hasNewHeading = heading.map {
            $0.timestamp != lastConsumedHeadingTimestamp
        } ?? false

        if case .collecting = estimator.calibrationState,
           let heading,
           hasNewHeading,
           heading.headingAccuracy >= 0 {
            lastConsumedHeadingTimestamp = heading.timestamp
            let absolute = heading.trueHeading >= 0
                ? heading.trueHeading
                : heading.magneticHeading
            estimator.addCalibrationSample(
                HeadingCalibrationSample(
                    timestamp: timestamp,
                    arCameraBearingDegrees: arCameraBearingDegrees,
                    absoluteCameraHeadingDegrees: absolute,
                    measurementStandardDeviationDegrees: max(
                        heading.headingAccuracy, 1
                    ),
                    magneticFieldMicrotesla: magneticFieldMicrotesla,
                    magneticQualityIsUsable: magneticQualityIsUsable
                )
            )
            publish()
            return
        } else if case .collecting = estimator.calibrationState {
            estimator.advanceCalibrationClock(to: timestamp)
            publish()
            return
        }

        estimator.predict(
            arCameraBearingDegrees: arCameraBearingDegrees,
            at: timestamp
        )

        // GPS course is the direction the phone is travelling, not the
        // direction its camera is facing. Using it as camera yaw can rotate a
        // stationary/high-rise scene toward an arbitrary GPS-drift bearing.
        if let heading,
           hasNewHeading,
           heading.headingAccuracy >= 0,
           heading.headingAccuracy
                <= HeadingEstimator.preciseStandardDeviationDegrees,
           magneticQualityIsUsable,
           magneticSampleIsFresh(at: timestamp),
           magneticMagnitudeIsPlausible {
            let absolute = heading.trueHeading >= 0
                ? heading.trueHeading
                : heading.magneticHeading
            let accepted = estimator.updateAbsoluteHeading(
                arCameraBearingDegrees: arCameraBearingDegrees,
                absoluteCameraHeadingDegrees: absolute,
                measurementStandardDeviationDegrees: max(
                    heading.headingAccuracy, 3
                ),
                source: .magnetometer,
                timestamp: timestamp
            )
            lastConsumedHeadingTimestamp = heading.timestamp
            if accepted {
                logger.debug("Accepted magnetic yaw update")
            }
        }
        publish()
    }

    func restartCalibration(at timestamp: TimeInterval) {
        logger.info("Restarting five-second heading calibration")
        lastConsumedHeadingTimestamp = nil
        estimator.startCalibration(at: timestamp)
        publish()
    }

    private func consume(_ motion: CMDeviceMotion) {
        let field = motion.magneticField.field
        let magnitude = sqrt(field.x * field.x + field.y * field.y + field.z * field.z)
        magneticFieldMicrotesla = magnitude
        lastMagneticUpdateTimestamp = motion.timestamp
        switch motion.magneticField.accuracy {
        case .high:
            magneticQuality = "high"
            magneticQualityIsUsable = true
        case .medium:
            magneticQuality = "medium"
            magneticQualityIsUsable = true
        case .low:
            magneticQuality = "low"
            magneticQualityIsUsable = false
        case .uncalibrated:
            magneticQuality = "uncalibrated"
            magneticQualityIsUsable = false
        @unknown default:
            magneticQuality = "unknown"
            magneticQualityIsUsable = false
        }
    }

    private func magneticSampleIsFresh(at timestamp: TimeInterval) -> Bool {
        guard let lastMagneticUpdateTimestamp else { return false }
        return abs(timestamp - lastMagneticUpdateTimestamp) <= 0.5
    }

    private var magneticMagnitudeIsPlausible: Bool {
        guard let magneticFieldMicrotesla else { return false }
        return (20...90).contains(magneticFieldMicrotesla)
    }

    private func publish() {
        let nextEstimate = estimator.estimate
        let headingChange = abs(HeadingEstimator.signedDeltaDegrees(
            from: estimate.cameraHeadingDegrees ?? nextEstimate.cameraHeadingDegrees ?? 0,
            to: nextEstimate.cameraHeadingDegrees ?? 0
        ))
        let offsetChange = abs(HeadingEstimator.signedDeltaDegrees(
            from: estimate.worldYawOffsetDegrees ?? nextEstimate.worldYawOffsetDegrees ?? 0,
            to: nextEstimate.worldYawOffsetDegrees ?? 0
        ))
        if estimate.isUsable != nextEstimate.isUsable
            || estimate.source != nextEstimate.source
            || headingChange >= 0.5
            || offsetChange >= 0.25
            || abs(estimate.standardDeviationDegrees - nextEstimate.standardDeviationDegrees) >= 0.25 {
            estimate = nextEstimate
        }
        if calibrationState != estimator.calibrationState {
            logger.info("Calibration state changed: \(String(describing: self.estimator.calibrationState), privacy: .public)")
            calibrationState = estimator.calibrationState
        }
    }
}
