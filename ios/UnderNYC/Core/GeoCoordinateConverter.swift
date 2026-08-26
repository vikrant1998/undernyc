import CoreLocation
import Foundation
import simd

enum GeoCoordinateConverter {
    private static let earthRadiusMeters = 6_371_008.8

    static func localARPosition(
        origin: CLLocationCoordinate2D,
        target: CLLocationCoordinate2D,
        depthMeters: Double
    ) -> SIMD3<Float> {
        let latitude1 = origin.latitude * .pi / 180
        let latitude2 = target.latitude * .pi / 180
        let longitudeDelta = (target.longitude - origin.longitude) * .pi / 180
        let latitudeDelta = latitude2 - latitude1
        let meanLatitude = (latitude1 + latitude2) / 2
        let north = earthRadiusMeters * latitudeDelta
        let east = earthRadiusMeters * longitudeDelta * cos(meanLatitude)
        return SIMD3(Float(east), Float(-depthMeters), Float(-north))
    }

    /// Keeps one literal geographic scale: one AR metre is one physical metre.
    /// Perspective already makes distant trains appear smaller. Compressing
    /// city distances moved a train away from its real coordinate and made a
    /// correct MTA estimate look as though it were beneath the wrong block.
    static func displayARPosition(
        origin: CLLocationCoordinate2D,
        target: CLLocationCoordinate2D,
        depthMeters: Double
    ) -> SIMD3<Float> {
        localARPosition(
            origin: origin,
            target: target,
            depthMeters: depthMeters
        )
    }

    /// Places a target in the persistent AR world using Core Location's true
    /// heading. The geographic origin is bound to the AR session origin, so
    /// the live camera translation must not be added here; doing that makes
    /// world content follow the phone and breaks marker/route registration.
    static func headingCorrectedDisplayARPosition(
        origin: CLLocationCoordinate2D,
        target: CLLocationCoordinate2D,
        depthMeters: Double,
        cameraTransform: simd_float4x4,
        trueHeadingDegrees: Double
    ) -> SIMD3<Float> {
        let local = displayARPosition(
            origin: origin,
            target: target,
            depthMeters: depthMeters
        )
        let cameraForward = SIMD2<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.z
        )
        guard simd_length(cameraForward) > 0.001 else { return local }

        let arCameraBearing = normalizedBearingDegrees(
            atan2(Double(cameraForward.x), Double(-cameraForward.y)) * 180 / .pi
        )
        let correction = (trueHeadingDegrees - arCameraBearing) * .pi / 180
        let cosine = Float(cos(correction))
        let sine = Float(sin(correction))
        let correctedX = cosine * local.x + sine * local.z
        let correctedZ = -sine * local.x + cosine * local.z
        return SIMD3(
            correctedX,
            local.y,
            correctedZ
        )
    }

    /// Retained as a shared scale contract for renderers and tests. Street AR
    /// is literal scale, so the displayed distance is the physical distance.
    static func displayedHorizontalDistance(for distanceMeters: Double) -> Double {
        max(0, distanceMeters)
    }

    static func uniformDisplayScale(for distanceMeters: Double) -> Float {
        _ = distanceMeters
        return 1
    }

    static func bearingDegrees(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> Double {
        let latitude1 = origin.latitude * .pi / 180
        let latitude2 = target.latitude * .pi / 180
        let longitudeDelta = (target.longitude - origin.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2)
            - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        return normalizedBearingDegrees(atan2(y, x) * 180 / .pi)
    }

    static func signedHeadingDeltaDegrees(from heading: Double, to bearing: Double) -> Double {
        var delta = normalizedBearingDegrees(bearing) - normalizedBearingDegrees(heading)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    static func headingCorrectionRadians(
        cameraTransform: simd_float4x4?,
        trueHeadingDegrees: Double?
    ) -> Double {
        guard let cameraTransform, let trueHeadingDegrees else { return 0 }
        let forward = SIMD2<Float>(
            -cameraTransform.columns.2.x, -cameraTransform.columns.2.z
        )
        guard simd_length(forward) > 0.001 else { return 0 }
        let arBearing = normalizedBearingDegrees(
            atan2(Double(forward.x), Double(-forward.y)) * 180 / .pi
        )
        return (trueHeadingDegrees - arBearing) * .pi / 180
    }

    static func distanceMeters(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> Double {
        let vector = localARPosition(origin: origin, target: target, depthMeters: 0)
        return Double(simd_length(SIMD2(vector.x, vector.z)))
    }

    static func advanced(
        from point: GeoPoint,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> GeoPoint {
        let angularDistance = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let latitude1 = point.latitude * .pi / 180
        let longitude1 = point.longitude * .pi / 180
        let latitude2 = asin(
            sin(latitude1) * cos(angularDistance)
                + cos(latitude1) * sin(angularDistance) * cos(bearing)
        )
        let longitude2 = longitude1 + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude1),
            cos(angularDistance) - sin(latitude1) * sin(latitude2)
        )
        return GeoPoint(
            latitude: latitude2 * 180 / .pi,
            longitude: longitude2 * 180 / .pi
        )
    }

    private static func normalizedBearingDegrees(_ degrees: Double) -> Double {
        let result = degrees.truncatingRemainder(dividingBy: 360)
        return result >= 0 ? result : result + 360
    }
}
