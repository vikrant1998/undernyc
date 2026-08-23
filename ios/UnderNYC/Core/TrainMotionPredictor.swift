import Foundation

enum TrainMotionPredictor {
    /// Returns the ordered static-shape path from the estimated train position
    /// to the next stop's shape-projected coordinate. The endpoint is selected
    /// by projecting the stop onto the ordered route rather than treating the
    /// stop centroid as an unconstrained geographic target.
    static func routeToNextStop(of train: NearbyTrain) -> [GeoPoint] {
        var route: [GeoPoint] = []
        for point in [train.position] + train.upcomingRoute {
            guard route.last != point else { continue }
            route.append(point)
        }
        guard let nextStop = train.nextStopPosition else {
            return route
        }
        guard route.count > 1 else {
            return route.last == nextStop ? route : route + [nextStop]
        }

        let expectedDistance: Double?
        if let mean = train.meanChainageMeters,
           let next = train.nextStopChainageMeters {
            expectedDistance = max(0, next - mean)
        } else {
            expectedDistance = nil
        }
        var cumulative = 0.0
        var bestIndex = 0
        var bestFraction = 1.0
        var bestScore = Double.infinity

        for index in 0..<(route.count - 1) {
            let start = route[index]
            let end = route[index + 1]
            let segmentLength = meters(from: start, to: end)
            guard segmentLength > 0.001 else { continue }
            let startVector = localMeters(from: nextStop, to: start)
            let endVector = localMeters(from: nextStop, to: end)
            let segment = endVector - startVector
            let denominator = max(
                segment.x * segment.x + segment.y * segment.y,
                1e-9
            )
            let fraction = min(
                max(
                    -(startVector.x * segment.x + startVector.y * segment.y)
                        / denominator,
                    0
                ),
                1
            )
            let closest = startVector + segment * fraction
            let residual = hypot(closest.x, closest.y)
            let alongDistance = cumulative + segmentLength * fraction
            // Spatial agreement dominates. Chainage breaks ties at crossings
            // or overlapping route geometry without requiring exact equality
            // between simplified-polyline and source-shape arc lengths.
            let chainagePenalty = expectedDistance.map {
                abs(alongDistance - $0) * 0.02
            } ?? 0
            let score = residual + chainagePenalty
            if score < bestScore {
                bestScore = score
                bestIndex = index
                bestFraction = fraction
            }
            cumulative += segmentLength
        }

        var result = Array(route[0...bestIndex])
        let projected = interpolate(
            from: route[bestIndex],
            to: route[bestIndex + 1],
            fraction: bestFraction
        )
        if result.last != projected { result.append(projected) }
        return result
    }

    static func position(of train: NearbyTrain, after seconds: TimeInterval) -> GeoPoint {
        position(
            of: train,
            distanceMeters: max(0, train.speedMetersPerSecond * seconds)
        )
    }

    static func position(
        of train: NearbyTrain,
        distanceMeters: Double
    ) -> GeoPoint {
        let remainingDistance = max(0, distanceMeters)
        guard remainingDistance > 0, !train.upcomingRoute.isEmpty else {
            return train.position
        }
        var previous = train.position
        var remaining = remainingDistance
        for point in train.upcomingRoute {
            let segment = meters(from: previous, to: point)
            if segment >= remaining, segment > 0 {
                let fraction = remaining / segment
                return GeoPoint(
                    latitude: previous.latitude
                        + (point.latitude - previous.latitude) * fraction,
                    longitude: previous.longitude
                        + (point.longitude - previous.longitude) * fraction
                )
            }
            remaining -= segment
            previous = point
        }
        return previous
    }

    static func meters(from start: GeoPoint, to end: GeoPoint) -> Double {
        let latitudeScale = 111_132.0
        let longitudeScale = 111_320.0 * cos((start.latitude + end.latitude) / 2 * .pi / 180)
        let north = (end.latitude - start.latitude) * latitudeScale
        let east = (end.longitude - start.longitude) * longitudeScale
        return hypot(north, east)
    }

    private static func localMeters(
        from origin: GeoPoint,
        to target: GeoPoint
    ) -> SIMD2<Double> {
        let latitudeScale = 111_132.0
        let longitudeScale = 111_320.0
            * cos((origin.latitude + target.latitude) / 2 * .pi / 180)
        return SIMD2(
            (target.longitude - origin.longitude) * longitudeScale,
            (target.latitude - origin.latitude) * latitudeScale
        )
    }

    private static func interpolate(
        from start: GeoPoint,
        to end: GeoPoint,
        fraction: Double
    ) -> GeoPoint {
        GeoPoint(
            latitude: start.latitude
                + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude
                + (end.longitude - start.longitude) * fraction
        )
    }
}
