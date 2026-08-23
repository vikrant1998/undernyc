import RealityKit
import UIKit

/// Builds a lightweight, full-consist subway train from RealityKit primitives.
/// Dimensions are in metres. At close range the model is approximately the
/// size of a six-car demo consist; geographic distance controls LOD.
@MainActor
enum TrainEntityFactory {
    private static let carCount = 6
    private static let carLength: Float = 13.4
    private static let carGap: Float = 0.45
    private static let carWidth: Float = 2.8
    private static let carHeight: Float = 3.2

    static func makeMarker(
        for train: NearbyTrain,
        selected: Bool,
        showDetailedModel: Bool
    ) -> ModelEntity {
        if !showDetailedModel {
            return makeUncertainTrain(for: train, selected: selected)
        }
        let consist = ModelEntity()
        consist.name = "train:\(train.id)"

        for index in 0..<carCount {
            let z = (Float(index) - Float(carCount - 1) / 2)
                * (carLength + carGap)
            let car = makeCar(
                index: index,
                routeColor: UIColor(hex: train.routeColor),
                selected: selected
            )
            car.position.z = z
            consist.addChild(car)
        }
        return consist
    }

    static func applyAppearance(
        to entity: ModelEntity,
        train: NearbyTrain,
        selected: Bool,
        distanceMeters: Float
    ) {
        let routeColor = UIColor(hex: train.routeColor)
        entity.visit { child in
            guard let model = child as? ModelEntity else { return }
            if model.name.hasPrefix("route-stripe") || model.name.hasPrefix("route-badge") {
                model.model?.materials = [metal(routeColor, metallic: false)]
            } else if model.name.hasPrefix("car-body") {
                let bodyColor = selected
                    ? UIColor(white: 0.96, alpha: 1)
                    : UIColor(white: 0.72, alpha: 1)
                model.model?.materials = [metal(bodyColor, metallic: true)]
            }
        }
        if entity.children.contains(where: { $0.name == "uncertain-single-car" }) {
            // Keep an uncertain estimate recognizable as a train without
            // implying that a full consist occupies this exact point.
            entity.scale = SIMD3(repeating: selected ? 0.30 : 0.18)
            return
        }
        entity.scale = SIMD3(repeating: visualScale(
            selected: selected,
            showDetailedModel: true,
            distanceMeters: distanceMeters,
            lifeSized: train.positionMethod == "cinematic_demo" && selected
        ))
    }

    private static func makeUncertainTrain(
        for train: NearbyTrain, selected: Bool
    ) -> ModelEntity {
        let root = ModelEntity()
        root.name = "train:\(train.id)"
        let routeColor = UIColor(hex: train.routeColor)

        let car = makeCar(
            index: 0,
            routeColor: routeColor,
            selected: selected
        )
        car.name = "uncertain-single-car"
        root.addChild(car)

        // This soft footprint is attached to the vehicle and means “estimated
        // position”; the larger route-aligned band carries the actual range.
        let footprint = ModelEntity(
            mesh: .generateBox(
                size: SIMD3(carWidth + 1.2, 0.08, carLength + 3.5),
                cornerRadius: 0.5
            ),
            materials: [SimpleMaterial(
                color: routeColor.withAlphaComponent(0.18),
                roughness: 0.2,
                isMetallic: false
            )]
        )
        footprint.name = "uncertainty-footprint"
        footprint.position.y = -carHeight / 2 - 0.45
        root.addChild(footprint)
        return root
    }

    /// Full physical scale nearby, reduced smoothly for city-scale targets.
    static func displayScale(distanceMeters: Float) -> Float {
        guard distanceMeters > 80 else { return 0.34 }
        if distanceMeters <= 250 {
            let t = (distanceMeters - 80) / 170
            return 0.34 - 0.06 * t
        }
        if distanceMeters <= 1_000 {
            let t = (distanceMeters - 250) / 750
            return 0.28 - 0.10 * t
        }
        return max(0.07, 0.18 * sqrt(1_000 / distanceMeters))
    }

    static func visualScale(
        selected: Bool,
        showDetailedModel: Bool,
        distanceMeters: Float,
        lifeSized: Bool = false
    ) -> Float {
        if lifeSized { return 1 }
        if !showDetailedModel { return selected ? 0.30 : 0.18 }
        return displayScale(distanceMeters: distanceMeters)
            * (selected ? 1.06 : 1)
    }

    static func displayedTrackGauge(
        selected: Bool,
        showDetailedModel: Bool,
        distanceMeters: Float,
        lifeSized: Bool = false
    ) -> Float {
        max(0.18, 1.435 * visualScale(
            selected: selected,
            showDetailedModel: showDetailedModel,
            distanceMeters: distanceMeters,
            lifeSized: lifeSized
        ))
    }

    static func displayedRailThickness(
        selected: Bool,
        showDetailedModel: Bool,
        distanceMeters: Float,
        lifeSized: Bool = false
    ) -> Float {
        max(0.028, 0.11 * visualScale(
            selected: selected,
            showDetailedModel: showDetailedModel,
            distanceMeters: distanceMeters,
            lifeSized: lifeSized
        ))
    }

    static func displayedUncertaintyWidth(
        selected: Bool,
        showDetailedModel: Bool,
        distanceMeters: Float,
        lifeSized: Bool = false
    ) -> Float {
        max(0.48, carWidth * 1.45 * visualScale(
            selected: selected,
            showDetailedModel: showDetailedModel,
            distanceMeters: distanceMeters,
            lifeSized: lifeSized
        ))
    }

    /// Height of the entity origin above the rail centerline after applying
    /// the same scale used by `applyAppearance`. The procedural car is built
    /// around its body center, not at wheel contact level.
    static func trackVerticalOffset(
        selected: Bool,
        showDetailedModel: Bool,
        distanceMeters: Float,
        lifeSized: Bool = false
    ) -> Float {
        let scale = visualScale(
            selected: selected,
            showDetailedModel: showDetailedModel,
            distanceMeters: distanceMeters,
            lifeSized: lifeSized
        )
        let bogieBottom = carHeight / 2 + 0.18 + 0.19
        return bogieBottom * scale + 0.05
    }

    /// Moves toward a new yaw through the shortest arc while bounding the
    /// amount a train may turn during one network refresh.
    static func stabilizedYaw(
        previous: Float?,
        desired: Float,
        maximumDelta: Float = .pi / 12
    ) -> Float {
        guard let previous else { return desired }
        let fullTurn = Float.pi * 2
        var delta = (desired - previous).truncatingRemainder(dividingBy: fullTurn)
        if delta > .pi { delta -= fullTurn }
        if delta < -.pi { delta += fullTurn }
        return previous + min(max(delta, -maximumDelta), maximumDelta)
    }

    private static func makeCar(
        index: Int,
        routeColor: UIColor,
        selected: Bool
    ) -> ModelEntity {
        let car = ModelEntity()
        car.name = "subway-car-\(index)"

        let body = part(
            name: "car-body-\(index)",
            size: SIMD3(carWidth, carHeight, carLength),
            color: selected ? UIColor.white : UIColor(white: 0.72, alpha: 1),
            metallic: true,
            cornerRadius: 0.28
        )
        body.generateCollisionShapes(recursive: false)
        car.addChild(body)

        let roof = part(
            name: "roof-\(index)",
            size: SIMD3(carWidth - 0.18, 0.24, carLength - 0.35),
            color: UIColor(white: 0.48, alpha: 1),
            metallic: true,
            cornerRadius: 0.1
        )
        roof.position.y = carHeight / 2 + 0.08
        car.addChild(roof)

        // Selection is conveyed by the brighter stainless-steel body and the
        // route-aligned glow. Keep the real service color on every consist so
        // selection never destroys line identity.
        let stripeColor = routeColor
        for side: Float in [-1, 1] {
            let stripe = part(
                name: "route-stripe-\(index)-\(side)",
                size: SIMD3(0.045, 0.24, carLength - 0.5),
                color: stripeColor,
                metallic: false
            )
            stripe.position = SIMD3(side * (carWidth / 2 + 0.025), -0.25, 0)
            car.addChild(stripe)

            for (windowIndex, windowZ) in [
                Float(-5.0), -3.35, -1.7, 1.7, 3.35, 5.0,
            ].enumerated() {
                let window = part(
                    name: "window-\(index)-\(side)-\(windowIndex)",
                    size: SIMD3(0.055, 0.72, 1.05),
                    color: UIColor(red: 0.025, green: 0.075, blue: 0.105, alpha: 1),
                    metallic: true,
                    cornerRadius: 0.1
                )
                window.position = SIMD3(
                    side * (carWidth / 2 + 0.035), 0.58, windowZ
                )
                car.addChild(window)
            }

            for (doorIndex, doorZ) in [Float(-0.82), 0.82].enumerated() {
                let door = part(
                    name: "door-\(index)-\(side)-\(doorIndex)",
                    size: SIMD3(0.06, 2.25, 1.3),
                    color: UIColor(white: 0.56, alpha: 1),
                    metallic: true,
                    cornerRadius: 0.04
                )
                door.position = SIMD3(
                    side * (carWidth / 2 + 0.045), -0.12, doorZ
                )
                car.addChild(door)
                let doorWindow = part(
                    name: "door-window-\(index)-\(side)-\(doorIndex)",
                    size: SIMD3(0.07, 0.58, 0.78),
                    color: UIColor(red: 0.025, green: 0.075, blue: 0.105, alpha: 1),
                    metallic: true,
                    cornerRadius: 0.07
                )
                doorWindow.position = SIMD3(
                    side * (carWidth / 2 + 0.065), 0.48, doorZ
                )
                car.addChild(doorWindow)
            }
        }

        for bogieZ: Float in [-4.4, 4.4] {
            let bogie = part(
                name: "bogie-\(index)",
                size: SIMD3(carWidth - 0.35, 0.38, 1.65),
                color: UIColor(white: 0.08, alpha: 1),
                metallic: true,
                cornerRadius: 0.12
            )
            bogie.position = SIMD3(0, -carHeight / 2 - 0.18, bogieZ)
            car.addChild(bogie)
        }

        if index == 0 || index == carCount - 1 {
            let endSign: Float = index == 0 ? -1 : 1
            let windshield = part(
                name: "front-window-\(index)",
                size: SIMD3(1.55, 0.9, 0.055),
                color: UIColor(red: 0.025, green: 0.07, blue: 0.1, alpha: 1),
                metallic: true,
                cornerRadius: 0.1
            )
            windshield.position = SIMD3(0, 0.52, endSign * (carLength / 2 + 0.035))
            car.addChild(windshield)

            let badge = part(
                name: "route-badge-\(index)",
                size: SIMD3(0.72, 0.72, 0.07),
                color: stripeColor,
                metallic: false,
                cornerRadius: 0.32
            )
            badge.position = SIMD3(0, -0.48, endSign * (carLength / 2 + 0.05))
            car.addChild(badge)

            for lightX: Float in [-0.72, 0.72] {
                let light = part(
                    name: "headlight-\(index)-\(lightX)",
                    size: SIMD3(0.25, 0.22, 0.08),
                    color: .white,
                    metallic: false,
                    cornerRadius: 0.1
                )
                light.position = SIMD3(
                    lightX, -0.72, endSign * (carLength / 2 + 0.06)
                )
                car.addChild(light)
            }
        }

        return car
    }

    private static func part(
        name: String,
        size: SIMD3<Float>,
        color: UIColor,
        metallic: Bool,
        cornerRadius: Float = 0.04
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: .generateBox(size: size, cornerRadius: cornerRadius),
            materials: [metal(color, metallic: metallic)]
        )
        entity.name = name
        return entity
    }

    private static func metal(_ color: UIColor, metallic: Bool) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: metallic ? 0.22 : 0.42, isMetallic: metallic)
    }
}

private extension Entity {
    func visit(_ action: (Entity) -> Void) {
        action(self)
        for child in children {
            child.visit(action)
        }
    }
}
