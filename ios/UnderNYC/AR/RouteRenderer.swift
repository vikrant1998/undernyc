import CoreLocation
import RealityKit
import UIKit

@MainActor
enum RouteRenderer {
    static func makeRoute(
        points: [GeoPoint],
        origin: CLLocationCoordinate2D,
        depthMeters: Double,
        color: UIColor,
        lineWidth: Float = 0.28,
        opacity: CGFloat = 0.75,
        railGauge: Float = 1.10,
        railThickness: Float = 0.10,
        cameraTransform: simd_float4x4? = nil,
        trueHeadingDegrees: Double? = nil
    ) -> Entity {
        let positions = projectedPositions(
            points: points,
            origin: origin,
            depthMeters: depthMeters,
            cameraTransform: cameraTransform,
            trueHeadingDegrees: trueHeadingDegrees
        )
        return makeRoute(
            positions: positions,
            color: color,
            lineWidth: lineWidth,
            opacity: opacity,
            railGauge: railGauge,
            railThickness: railThickness
        )
    }

    /// Projects every route vertex through the exact same global mapping used
    /// by train markers. A route must never apply model LOD or a second local
    /// scale: doing so makes it mathematically impossible for its train to sit
    /// on the rendered rails beyond the first vertex.
    static func projectedPositions(
        points: [GeoPoint],
        origin: CLLocationCoordinate2D,
        depthMeters: Double,
        cameraTransform: simd_float4x4? = nil,
        trueHeadingDegrees: Double? = nil
    ) -> [SIMD3<Float>] {
        points.map { point in
            let coordinate = CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
            if let cameraTransform, let trueHeadingDegrees {
                return GeoCoordinateConverter.headingCorrectedDisplayARPosition(
                    origin: origin,
                    target: coordinate,
                    depthMeters: depthMeters,
                    cameraTransform: cameraTransform,
                    trueHeadingDegrees: trueHeadingDegrees
                )
            }
            return GeoCoordinateConverter.displayARPosition(
                origin: origin,
                target: coordinate,
                depthMeters: depthMeters
            )
        }
    }

    static func makeRoute(
        positions: [SIMD3<Float>],
        color: UIColor,
        lineWidth: Float = 0.28,
        opacity: CGFloat = 0.75,
        railGauge: Float = 1.10,
        railThickness: Float = 0.10
    ) -> Entity {
        let route = Entity()
        route.name = "selected-route"
        for (start, end) in zip(positions, positions.dropFirst()) {
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.1 else { continue }
            if lineWidth <= 0.3 {
                addTrackSegment(
                    to: route,
                    start: start,
                    end: end,
                    delta: delta,
                    length: length,
                    color: color,
                    opacity: opacity,
                    railGauge: railGauge,
                    railThickness: railThickness
                )
                continue
            }
            let mesh = MeshResource.generateBox(
                size: SIMD3<Float>(lineWidth, length, lineWidth),
                cornerRadius: min(lineWidth / 2, 0.3)
            )
            let material = SimpleMaterial(
                color: color.withAlphaComponent(opacity),
                roughness: 0.35,
                isMetallic: false
            )
            let segment = ModelEntity(mesh: mesh, materials: [material])
            segment.position = (start + end) / 2
            segment.orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(delta)
            )
            route.addChild(segment)
        }
        return route
    }

    /// Draws one lightweight schematic line for a train's complete route.
    /// The detailed selected segment still uses the two-rail renderer above.
    static func makeCenterline(
        positions: [SIMD3<Float>],
        color: UIColor,
        width: Float = 0.055,
        opacity: CGFloat = 0.30
    ) -> Entity {
        let route = Entity()
        route.name = "route-overview"
        let material = SimpleMaterial(
            color: color.withAlphaComponent(opacity),
            roughness: 0.45,
            isMetallic: false
        )
        for (start, end) in zip(positions, positions.dropFirst()) {
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.1 else { continue }
            let segment = ModelEntity(
                mesh: .generateBox(
                    size: SIMD3<Float>(width, length, width),
                    cornerRadius: width / 2
                ),
                materials: [material]
            )
            segment.position = (start + end) / 2
            segment.orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(delta)
            )
            route.addChild(segment)
        }
        return route
    }

    /// Samples the exact piecewise-linear geometry that is rendered. Using
    /// this for train motion guarantees that the marker cannot cut across a
    /// curve or drift away from the geometry that is actually displayed.
    static func position(
        along positions: [SIMD3<Float>],
        progress: Double
    ) -> SIMD3<Float>? {
        guard let first = positions.first else { return nil }
        guard positions.count > 1 else { return first }
        let lengths = zip(positions, positions.dropFirst()).map {
            simd_length($1 - $0)
        }
        let total = lengths.reduce(0, +)
        guard total > 0.0001 else { return first }
        var remaining = Float(min(max(progress, 0), 1)) * total
        for (index, length) in lengths.enumerated() {
            if remaining <= length, length > 0.0001 {
                return simd_mix(
                    positions[index],
                    positions[index + 1],
                    SIMD3<Float>(repeating: remaining / length)
                )
            }
            remaining -= length
        }
        return positions.last
    }

    static func direction(
        along positions: [SIMD3<Float>],
        progress: Double
    ) -> SIMD2<Float>? {
        guard positions.count > 1 else { return nil }
        let lengths = zip(positions, positions.dropFirst()).map {
            simd_length($1 - $0)
        }
        let total = lengths.reduce(0, +)
        guard total > 0.0001 else { return nil }
        var remaining = Float(min(max(progress, 0), 1)) * total
        for (index, length) in lengths.enumerated() {
            if remaining <= length, length > 0.0001 {
                let delta = positions[index + 1] - positions[index]
                let horizontal = SIMD2(delta.x, delta.z)
                return simd_length(horizontal) > 0.0001
                    ? simd_normalize(horizontal)
                    : nil
            }
            remaining -= length
        }
        let delta = positions[positions.count - 1]
            - positions[positions.count - 2]
        let horizontal = SIMD2(delta.x, delta.z)
        return simd_length(horizontal) > 0.0001
            ? simd_normalize(horizontal)
            : nil
    }

    private static func addTrackSegment(
        to route: Entity,
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        delta: SIMD3<Float>,
        length: Float,
        color: UIColor,
        opacity: CGFloat,
        railGauge: Float,
        railThickness: Float
    ) {
        let direction = simd_normalize(delta)
        var side = simd_cross(SIMD3<Float>(0, 1, 0), direction)
        if simd_length(side) < 0.001 { side = SIMD3<Float>(1, 0, 0) }
        side = simd_normalize(side)
        let orientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: direction
        )
        let railMaterial = SimpleMaterial(
            color: color.withAlphaComponent(opacity),
            roughness: 0.28,
            isMetallic: true
        )
        for offset: Float in [-railGauge / 2, railGauge / 2] {
            let rail = ModelEntity(
                mesh: .generateBox(
                    size: SIMD3<Float>(railThickness, length, railThickness),
                    cornerRadius: min(railThickness / 2, 0.04)
                ),
                materials: [railMaterial]
            )
            rail.position = (start + end) / 2 + side * offset
            rail.orientation = orientation
            route.addChild(rail)
        }
    }
}
