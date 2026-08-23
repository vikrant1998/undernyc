import CoreLocation
import simd
import XCTest
@testable import UnderNYC

final class GeoCoordinateConverterTests: XCTestCase {
    func testNorthMapsToNegativeZAndEastMapsToPositiveX() {
        let origin = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let north = GeoCoordinateConverter.localARPosition(
            origin: origin,
            target: CLLocationCoordinate2D(latitude: 40.751, longitude: -73.99),
            depthMeters: 15
        )
        XCTAssertLessThan(north.z, -100)
        XCTAssertEqual(north.y, -15, accuracy: 0.001)

        let east = GeoCoordinateConverter.localARPosition(
            origin: origin,
            target: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.989),
            depthMeters: 15
        )
        XCTAssertGreaterThan(east.x, 80)
    }

    func testMotionPredictorAdvancesAlongRoute() {
        let now = Date()
        let train = NearbyTrain(
            id: "train",
            line: "A",
            routeColor: "#0039A6",
            textColor: "#FFFFFF",
            direction: "North",
            previousStation: "One",
            nextStation: "Two",
            etaSeconds: 60,
            etaTime: now.addingTimeInterval(60),
            position: GeoPoint(latitude: 40.7000, longitude: -74),
            bearingDegrees: 0,
            speedMetersPerSecond: 10,
            distanceFromUserMeters: 100,
            approximateDepthMeters: 15,
            observedAt: now,
            validUntil: now.addingTimeInterval(30),
            estimateQuality: .high,
            upcomingRoute: [GeoPoint(latitude: 40.7100, longitude: -74)]
        )
        let predicted = TrainMotionPredictor.position(of: train, after: 10)
        XCTAssertGreaterThan(predicted.latitude, train.position.latitude)
        XCTAssertLessThan(predicted.latitude, 40.71)
    }

    func testFarTargetsKeepBearingButRenderInsideCityScaleRange() {
        let origin = CLLocationCoordinate2D(latitude: 40.7272, longitude: -74.0338)
        let target = CLLocationCoordinate2D(latitude: 40.7193, longitude: -74.0069)
        let truePosition = GeoCoordinateConverter.localARPosition(
            origin: origin, target: target, depthMeters: 15
        )
        let displayPosition = GeoCoordinateConverter.displayARPosition(
            origin: origin, target: target, depthMeters: 15
        )
        let trueDistance = hypot(truePosition.x, truePosition.z)
        let displayDistance = hypot(displayPosition.x, displayPosition.z)
        XCTAssertGreaterThan(trueDistance, 2_000)
        XCTAssertLessThan(displayDistance, 80)
        XCTAssertEqual(
            truePosition.x / truePosition.z,
            displayPosition.x / displayPosition.z,
            accuracy: 0.001
        )
        XCTAssertEqual(
            displayPosition.y / displayDistance,
            truePosition.y / trueDistance,
            accuracy: 0.001
        )
    }

    func testCityScaleCompressionRemainsStrictlyMonotonic() {
        let origin = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let near = GeoCoordinateConverter.displayARPosition(
            origin: origin,
            target: CLLocationCoordinate2D(latitude: 40.7545, longitude: -73.99),
            depthMeters: 15
        )
        let far = GeoCoordinateConverter.displayARPosition(
            origin: origin,
            target: CLLocationCoordinate2D(latitude: 40.759, longitude: -73.99),
            depthMeters: 15
        )
        XCTAssertGreaterThan(
            simd_length(SIMD2(far.x, far.z)),
            simd_length(SIMD2(near.x, near.z))
        )
    }

    func testHeadingCorrectionDoesNotFollowLiveCameraTranslation() {
        let origin = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let target = CLLocationCoordinate2D(latitude: 40.751, longitude: -73.989)
        var movedCamera = matrix_identity_float4x4
        movedCamera.columns.3 = SIMD4<Float>(12, 4, -8, 1)
        let atOrigin = GeoCoordinateConverter.headingCorrectedDisplayARPosition(
            origin: origin,
            target: target,
            depthMeters: 15,
            cameraTransform: matrix_identity_float4x4,
            trueHeadingDegrees: 42
        )
        let afterWalking = GeoCoordinateConverter.headingCorrectedDisplayARPosition(
            origin: origin,
            target: target,
            depthMeters: 15,
            cameraTransform: movedCamera,
            trueHeadingDegrees: 42
        )
        XCTAssertEqual(atOrigin.x, afterWalking.x, accuracy: 0.001)
        XCTAssertEqual(atOrigin.y, afterWalking.y, accuracy: 0.001)
        XCTAssertEqual(atOrigin.z, afterWalking.z, accuracy: 0.001)
    }

    func testHeadingCorrectionAlignsTargetToLiveCompassFrame() {
        let origin = CLLocationCoordinate2D(latitude: 40.7272, longitude: -74.0338)
        let target = CLLocationCoordinate2D(latitude: 40.7272, longitude: -74.0038)
        let corrected = GeoCoordinateConverter.headingCorrectedDisplayARPosition(
            origin: origin,
            target: target,
            depthMeters: 15,
            cameraTransform: matrix_identity_float4x4,
            trueHeadingDegrees: 90
        )
        XCTAssertEqual(corrected.x, 0, accuracy: 0.01)
        XCTAssertLessThan(corrected.z, -50)
        XCTAssertLessThan(corrected.y, 0)
    }

    func testBearingAndTurnDirectionFromNewportToLowerManhattan() {
        let newport = CLLocationCoordinate2D(latitude: 40.7272, longitude: -74.0338)
        let lowerManhattan = CLLocationCoordinate2D(latitude: 40.7193, longitude: -74.0069)
        let bearing = GeoCoordinateConverter.bearingDegrees(
            from: newport, to: lowerManhattan
        )
        XCTAssertEqual(bearing, 111, accuracy: 1)
        XCTAssertGreaterThan(
            GeoCoordinateConverter.signedHeadingDeltaDegrees(from: 90, to: bearing),
            0
        )
    }

    @MainActor
    func testTrainModelUsesPhysicalScaleNearbyAndShrinksAtDistance() {
        XCTAssertEqual(TrainEntityFactory.displayScale(distanceMeters: 40), 0.34)
        XCTAssertLessThan(TrainEntityFactory.displayScale(distanceMeters: 500), 0.28)
        XCTAssertLessThan(TrainEntityFactory.displayScale(distanceMeters: 2_000), 0.18)
        XCTAssertGreaterThanOrEqual(TrainEntityFactory.displayScale(distanceMeters: 20_000), 0.07)
    }

    func testDetailedTrainRequiresNarrowMatchedChainageInterval() {
        let now = Date()
        let train = NearbyTrain(
            id: "train-detail",
            line: "1",
            routeColor: "#EE352E",
            textColor: "#FFFFFF",
            direction: "Toward Van Cortlandt Park–242 St",
            previousStation: "96 St",
            nextStation: "103 St",
            etaSeconds: 60,
            etaTime: now.addingTimeInterval(60),
            position: GeoPoint(latitude: 40.795, longitude: -73.972),
            bearingDegrees: 0,
            speedMetersPerSecond: 10,
            distanceFromUserMeters: 100,
            approximateDepthMeters: 15,
            observedAt: now,
            validUntil: now.addingTimeInterval(45),
            estimateQuality: .medium,
            lowerChainageMeters: 1_000,
            upperChainageMeters: 1_100,
            shapeValidity: "matched",
            upcomingRoute: []
        )
        XCTAssertEqual(train.destinationLabel, "Van Cortlandt Park–242 St")
        XCTAssertTrue(train.supportsDetailedTrainModel)
    }

    @MainActor
    func testTrainYawUsesShortestArcAndBoundedTurnRate() {
        let previous = Float.pi - 0.05
        let desired = -Float.pi + 0.05
        let result = TrainEntityFactory.stabilizedYaw(
            previous: previous,
            desired: desired,
            maximumDelta: 0.2
        )
        XCTAssertEqual(result - previous, 0.1, accuracy: 0.001)

        let bounded = TrainEntityFactory.stabilizedYaw(
            previous: 0,
            desired: Float.pi,
            maximumDelta: 0.2
        )
        XCTAssertEqual(abs(bounded), 0.2, accuracy: 0.001)
    }
}
