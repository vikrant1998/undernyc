import XCTest
@testable import UnderNYC

final class HeadingEstimatorTests: XCTestCase {
    func testImmediateHeadingInitializationNeedsNoRotation() {
        var estimator = HeadingEstimator()
        XCTAssertTrue(estimator.initializeAbsoluteHeading(
            arCameraBearingDegrees: 15,
            absoluteCameraHeadingDegrees: 105,
            measurementStandardDeviationDegrees: 6,
            timestamp: 1
        ))
        XCTAssertEqual(estimator.calibrationState, .ready)
        XCTAssertTrue(estimator.estimate.isUsable)
        XCTAssertEqual(
            estimator.estimate.worldYawOffsetDegrees ?? -1,
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            estimator.estimate.cameraHeadingDegrees ?? -1,
            105,
            accuracy: 0.001
        )
    }

    func testCalibrationHandlesAngleWraparoundAndBecomesUsable() {
        var estimator = HeadingEstimator()
        estimator.startCalibration(at: 100)
        for index in 0..<151 {
            let bearing = Double(index) * 2
            estimator.addCalibrationSample(
                HeadingCalibrationSample(
                    timestamp: 100 + Double(index) / 30,
                    arCameraBearingDegrees: bearing,
                    absoluteCameraHeadingDegrees: HeadingEstimator.normalizeDegrees(
                        bearing + 355
                    ),
                    measurementStandardDeviationDegrees: 3,
                    magneticFieldMicrotesla: 49,
                    magneticQualityIsUsable: true
                )
            )
        }
        XCTAssertEqual(estimator.calibrationState, .ready)
        estimator.predict(arCameraBearingDegrees: 10, at: 106)
        XCTAssertTrue(estimator.estimate.isUsable)
        XCTAssertEqual(estimator.estimate.cameraHeadingDegrees ?? -1, 5, accuracy: 0.5)
    }

    func testInsufficientRotationFailsClosed() {
        var estimator = HeadingEstimator()
        estimator.startCalibration(at: 0)
        for index in 0..<151 {
            estimator.addCalibrationSample(
                HeadingCalibrationSample(
                    timestamp: Double(index) / 30,
                    arCameraBearingDegrees: Double(index) * 0.3,
                    absoluteCameraHeadingDegrees: 90 + Double(index) * 0.3,
                    measurementStandardDeviationDegrees: 3,
                    magneticFieldMicrotesla: 50,
                    magneticQualityIsUsable: true
                )
            )
        }
        guard case .failed = estimator.calibrationState else {
            return XCTFail("Expected calibration failure")
        }
        XCTAssertFalse(estimator.estimate.isUsable)
    }

    func testRejectedAbsoluteUpdateDoesNotMoveMean() {
        var estimator = calibratedEstimator()
        estimator.predict(arCameraBearingDegrees: 30, at: 6)
        let before = estimator.estimate.worldYawOffsetDegrees
        let accepted = estimator.updateAbsoluteHeading(
            arCameraBearingDegrees: 30,
            absoluteCameraHeadingDegrees: 220,
            measurementStandardDeviationDegrees: 2,
            source: .magnetometer,
            timestamp: 6.1
        )
        XCTAssertFalse(accepted)
        XCTAssertEqual(
            estimator.estimate.worldYawOffsetDegrees,
            before
        )
    }

    func testImplausibleMagneticMagnitudeIsExcluded() {
        var estimator = HeadingEstimator()
        estimator.startCalibration(at: 0)
        for index in 0..<151 {
            estimator.addCalibrationSample(
                HeadingCalibrationSample(
                    timestamp: Double(index) / 30,
                    arCameraBearingDegrees: Double(index) * 2,
                    absoluteCameraHeadingDegrees: Double(index) * 2 + 20,
                    measurementStandardDeviationDegrees: 3,
                    magneticFieldMicrotesla: 180,
                    magneticQualityIsUsable: true
                )
            )
        }
        guard case .failed = estimator.calibrationState else {
            return XCTFail("Expected calibration failure")
        }
    }

    private func calibratedEstimator() -> HeadingEstimator {
        var estimator = HeadingEstimator()
        estimator.startCalibration(at: 0)
        for index in 0..<151 {
            let bearing = Double(index) * 2
            estimator.addCalibrationSample(
                HeadingCalibrationSample(
                    timestamp: Double(index) / 30,
                    arCameraBearingDegrees: bearing,
                    absoluteCameraHeadingDegrees: HeadingEstimator.normalizeDegrees(
                        bearing + 25
                    ),
                    measurementStandardDeviationDegrees: 3,
                    magneticFieldMicrotesla: 50,
                    magneticQualityIsUsable: true
                )
            )
        }
        return estimator
    }
}
