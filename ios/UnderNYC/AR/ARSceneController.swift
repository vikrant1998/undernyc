import ARKit
import CoreLocation
import Foundation
import RealityKit
import UIKit

enum StreetLocalizationMode: Equatable {
    case checkingAvailability
    case visualLocalizing
    case visuallyLocalized
    case cinematicDemo
    case unavailable

    var isPrecise: Bool {
        switch self {
        case .visuallyLocalized, .cinematicDemo:
            true
        default:
            false
        }
    }
}

extension ARSceneController: ARSessionDelegate {
    nonisolated func session(
        _ session: ARSession,
        didChange geoTrackingStatus: ARGeoTrackingStatus
    ) {
        Task { @MainActor [weak self] in
            self?.handleGeoTrackingStatus(geoTrackingStatus)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        forwardGeoAnchors(anchors, removed: false)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        forwardGeoAnchors(anchors, removed: false)
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        forwardGeoAnchors(anchors, removed: true)
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.handleSessionInterruption()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.restartCurrentTrackingSession()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleSessionFailure(message)
        }
    }

    nonisolated private func forwardGeoAnchors(
        _ anchors: [ARAnchor],
        removed: Bool
    ) {
        for anchor in anchors {
            guard let geo = anchor as? ARGeoAnchor else { continue }
            Task { @MainActor [weak self] in
                self?.handleGeoOriginAnchor(
                    anchor: geo,
                    removed: removed
                )
            }
        }
    }

}

@MainActor
final class ARSceneController: NSObject, ObservableObject {
    private static let arrivalTrackYOffset: Float = -1.45

    private struct VisualProgress {
        let segmentID: String?
        var chainageMeters: Double
        var nextStopChainageMeters: Double
        var speedMetersPerSecond: Double
        var updatedAt: TimeInterval
        var sourceObservedAt: Date
        var sourceMeanChainageMeters: Double

        func chainage(at timestamp: TimeInterval) -> Double {
            min(
                nextStopChainageMeters,
                chainageMeters
                    + speedMetersPerSecond * max(0, timestamp - updatedAt)
            )
        }
    }

    @Published private(set) var edgeIndicator = EdgeIndicatorState()
    @Published private(set) var trackingDescription = "Starting AR"
    @Published private(set) var arrivalAligned = false
    @Published private(set) var viewHeadingDegrees: Double?
    @Published private(set) var streetLocalizationMode: StreetLocalizationMode =
        .checkingAvailability

    let arView = ARView(frame: .zero)
    var onTrainSelected: ((String?) -> Void)?
    var onCameraOrientationSample: ((Double, TimeInterval) -> Void)?

    private var origin: CLLocationCoordinate2D?
    private var currentCoordinate: CLLocationCoordinate2D?
    private var currentAltitudeMeters: Double?
    private var altitudeReferenceMeters: Double?
    private var currentHeadingEstimate = HeadingEstimate.unavailable
    private var displayMode: ARDisplayMode = .street
    private var root = AnchorEntity(world: .zero)
    private let contentRoot = Entity()
    private var markers: [String: ModelEntity] = [:]
    private var detailedMarkerIDs = Set<String>()
    private var markerYawRadians: [String: Float] = [:]
    private var markerSegmentIDs: [String: String] = [:]
    private var visualProgress: [String: VisualProgress] = [:]
    private var projectedMarkerPaths: [String: [SIMD3<Float>]] = [:]
    private var overviewRouteEntities: [String: Entity] = [:]
    private var overviewRouteSignatures: [String: String] = [:]
    private var latestTrains: [String: NearbyTrain] = [:]
    private var selectedID: String?
    private var routeEntity: Entity?
    private var arrivalAxisForward: SIMD3<Float>?
    private var arrivalAnchorPosition: SIMD3<Float>?
    private var arrivalInitialDistanceMeters: Double?
    private var arrivalAlignedSegmentID: String?
    private var indicatorTimer: Timer?
    private var isRunning = false
    private var geoAvailabilityCheckInFlight = false
    private var isGeoTrackingSession = false
    private var cinematicDemoEnabled = false
    private var geoOriginAnchorID: UUID?
    private var geoOriginTransform: simd_float4x4?
    private var geoTrackingIsLocalized = false

    override init() {
        super.init()
        root.addChild(contentRoot)
        arView.session.delegate = self
        arView.environment.sceneUnderstanding.options = []
        arView.renderOptions.insert(.disableMotionBlur)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
        indicatorTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advanceMarkers()
                self?.updateIndicator()
            }
        }
    }

    func start(at location: CLLocation) {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingDescription = "AR world tracking is unavailable on this iPhone"
            return
        }
        // Platform mode owns a separate gravity-only AR session. GPS drift
        // must never reset or replace that manually aligned local frame.
        guard displayMode == .street else {
            currentCoordinate = location.coordinate
            return
        }
        if let origin,
           GeoCoordinateConverter.distanceMeters(
               from: origin, to: location.coordinate
           ) > 150 {
            reset(at: location.coordinate)
            return
        }
        guard !isRunning else { return }
        origin = location.coordinate
        currentCoordinate = location.coordinate
        updateAltitude(from: location, relativeAltitudeMeters: nil)
        beginBestAvailableStreetSession(at: location)
    }

    private func beginBestAvailableStreetSession(at location: CLLocation) {
        guard displayMode == .street else { return }
        if cinematicDemoEnabled {
            runCinematicDemoSession()
            return
        }
        // Never leave geometry from the previous session visible while a new
        // geographic solution is being acquired.
        root.isEnabled = false
        edgeIndicator = EdgeIndicatorState()
        guard !geoAvailabilityCheckInFlight else { return }
        guard ARGeoTrackingConfiguration.isSupported else {
            runOutdoorUnavailableSession()
            return
        }
        geoAvailabilityCheckInFlight = true
        streetLocalizationMode = .checkingAvailability
        trackingDescription = "Checking Apple visual geolocation"
        ARGeoTrackingConfiguration.checkAvailability(
            at: location.coordinate
        ) { @Sendable [weak self] available, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.geoAvailabilityCheckInFlight = false
                guard !self.cinematicDemoEnabled,
                      self.displayMode == .street else { return }
                if available {
                    self.runGeoTrackingSession()
                } else {
                    self.runOutdoorUnavailableSession()
                }
            }
        }
    }

    private func runGeoTrackingSession() {
        prepareRootForNewSession()
        let configuration = ARGeoTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        arView.scene.addAnchor(root)
        isRunning = true
        isGeoTrackingSession = true
        contentRoot.orientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        streetLocalizationMode = .visualLocalizing
        trackingDescription = "Matching the camera view to Apple Maps"
    }

    private func runOutdoorUnavailableSession() {
        prepareRootForNewSession()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        arView.scene.addAnchor(root)
        isRunning = true
        isGeoTrackingSession = false
        contentRoot.orientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        root.isEnabled = false
        streetLocalizationMode = .unavailable
        trackingDescription = "Outdoor visual positioning unavailable"
    }

    private func runCinematicDemoSession() {
        prepareRootForNewSession()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        arView.scene.addAnchor(root)
        isRunning = true
        isGeoTrackingSession = false
        contentRoot.orientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        root.isEnabled = true
        streetLocalizationMode = .cinematicDemo
        trackingDescription = "Cinematic demo — simulated route"
    }

    private func runArrivalTrackingSession() {
        prepareRootForNewSession()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .automatic
        arView.session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        arView.scene.addAnchor(root)
        isRunning = true
        isGeoTrackingSession = false
        root.transform.matrix = matrix_identity_float4x4
        root.isEnabled = false
        trackingDescription = "Platform tracking ready — align incoming track"
    }

    private func prepareRootForNewSession() {
        root.removeFromParent()
        contentRoot.removeFromParent()
        root = AnchorEntity(world: .zero)
        root.addChild(contentRoot)
        geoOriginAnchorID = nil
        geoOriginTransform = nil
        geoTrackingIsLocalized = false
    }

    func reset(at coordinate: CLLocationCoordinate2D) {
        origin = coordinate
        currentCoordinate = coordinate
        viewHeadingDegrees = nil
        markers.removeAll()
        detailedMarkerIDs.removeAll()
        markerYawRadians.removeAll()
        markerSegmentIDs.removeAll()
        visualProgress.removeAll()
        projectedMarkerPaths.removeAll()
        overviewRouteEntities.removeAll()
        overviewRouteSignatures.removeAll()
        contentRoot.children.removeAll()
        routeEntity = nil
        clearArrivalAlignment()
        isRunning = false
        geoAvailabilityCheckInFlight = false
        let altitude = currentAltitudeMeters ?? 0
        beginBestAvailableStreetSession(at: CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 20,
            verticalAccuracy: 50,
            timestamp: .now
        ))
    }

    @discardableResult
    func alignArrivalView() -> Bool {
        guard displayMode == .arrival,
              selectedID != nil,
              let frame = arView.session.currentFrame
        else { return false }
        let rawForward = SIMD3<Float>(
            -frame.camera.transform.columns.2.x,
            0,
            -frame.camera.transform.columns.2.z
        )
        guard simd_length(rawForward) > 0.001 else { return false }
        arrivalAxisForward = simd_normalize(rawForward)
        arrivalAnchorPosition = SIMD3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        if let selectedID,
           let train = latestTrains[selectedID],
           let nextStop = visualProgress[selectedID]?.nextStopChainageMeters
                ?? train.nextStopChainageMeters,
           let current = visualProgress[selectedID]?.chainage(
                at: ProcessInfo.processInfo.systemUptime
           ) ?? train.meanChainageMeters {
            arrivalInitialDistanceMeters = max(1, nextStop - current)
        } else {
            arrivalInitialDistanceMeters = nil
        }
        arrivalAligned = true
        arrivalAlignedSegmentID = latestTrains[selectedID ?? ""]?.segmentId
        root.isEnabled = true
        resyncCurrentScene()
        return true
    }

    func flipArrivalAlignment() {
        guard let axis = arrivalAxisForward else { return }
        arrivalAxisForward = -axis
        resyncCurrentScene()
    }

    func clearArrivalAlignment() {
        arrivalAxisForward = nil
        arrivalAnchorPosition = nil
        arrivalInitialDistanceMeters = nil
        arrivalAlignedSegmentID = nil
        arrivalAligned = false
        if displayMode == .arrival { root.isEnabled = false }
    }

    func retryAutomaticStreetLocalization() {
        guard displayMode == .street, let coordinate = currentCoordinate else {
            return
        }
        contentRoot.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        isRunning = false
        let altitude = currentAltitudeMeters ?? 0
        beginBestAvailableStreetSession(at: CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 20,
            verticalAccuracy: 50,
            timestamp: .now
        ))
    }

    func setCinematicDemoEnabled(_ enabled: Bool, at location: CLLocation) {
        guard cinematicDemoEnabled != enabled else { return }
        cinematicDemoEnabled = enabled
        origin = location.coordinate
        currentCoordinate = location.coordinate
        updateAltitude(from: location, relativeAltitudeMeters: nil)
        isRunning = false
        geoAvailabilityCheckInFlight = false
        if enabled {
            runCinematicDemoSession()
        } else {
            beginBestAvailableStreetSession(at: location)
        }
    }

    private func handleGeoTrackingStatus(_ status: ARGeoTrackingStatus) {
        guard isGeoTrackingSession, !cinematicDemoEnabled else { return }
        switch (status.state, status.accuracy) {
        case (.localized, .high), (.localized, .medium):
            geoTrackingIsLocalized = true
            installGeoOriginAnchorIfNeeded()
            if geoOriginTransform == nil {
                streetLocalizationMode = .visualLocalizing
                trackingDescription = "Locking subway view to this street"
                root.isEnabled = false
            }
        case (.notAvailable, _):
            geoTrackingIsLocalized = false
            streetLocalizationMode = .unavailable
            trackingDescription = "Outdoor visual positioning unavailable"
            root.isEnabled = false
        default:
            geoTrackingIsLocalized = false
            streetLocalizationMode = .visualLocalizing
            trackingDescription = "Matching the camera view to Apple Maps"
            root.isEnabled = false
            edgeIndicator = EdgeIndicatorState()
        }
    }

    private func handleSessionInterruption() {
        root.isEnabled = false
        edgeIndicator = EdgeIndicatorState()
        trackingDescription = "AR paused"
    }

    private func handleSessionFailure(_ message: String) {
        root.isEnabled = false
        edgeIndicator = EdgeIndicatorState()
        trackingDescription = "AR session failed: \(message)"
        if displayMode == .street {
            streetLocalizationMode = .unavailable
        }
    }

    private func restartCurrentTrackingSession() {
        clearArrivalAlignment()
        isRunning = false
        geoAvailabilityCheckInFlight = false
        if displayMode == .arrival {
            runArrivalTrackingSession()
            return
        }
        guard let coordinate = currentCoordinate else { return }
        let altitude = currentAltitudeMeters ?? 0
        beginBestAvailableStreetSession(at: CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 20,
            verticalAccuracy: 50,
            timestamp: .now
        ))
    }

    private func installGeoOriginAnchorIfNeeded() {
        guard geoOriginAnchorID == nil, let origin else { return }
        let anchor = ARGeoAnchor(
            name: "undernyc-session-origin",
            coordinate: origin
        )
        geoOriginAnchorID = anchor.identifier
        arView.session.add(anchor: anchor)
    }

    private func handleGeoOriginAnchor(anchor: ARGeoAnchor, removed: Bool) {
        guard anchor.identifier == geoOriginAnchorID else { return }
        if removed {
            geoOriginTransform = nil
            root.isEnabled = false
            streetLocalizationMode = .unavailable
            trackingDescription = "Geographic anchor was lost — retry outdoors"
            return
        }
        guard anchor.isTracked, geoTrackingIsLocalized else {
            root.isEnabled = false
            return
        }
        let acquiredFirstLock = geoOriginTransform == nil
        geoOriginTransform = anchor.transform
        if displayMode == .street, acquiredFirstLock {
            // Tie RealityKit to the actual geographic ARAnchor. Copying the
            // transform into an unrelated `.world` AnchorEntity is weaker:
            // RealityKit owns world-anchor placement and may move it back to
            // its configured target. The ARAnchor-backed entity follows every
            // geotracking refinement automatically.
            root.removeFromParent()
            contentRoot.removeFromParent()
            // Target the session anchor by identifier. This API is available
            // throughout our iOS 17 deployment range; the newer convenience
            // initializer links against a symbol absent from iOS 17.2.
            root = AnchorEntity(.anchor(identifier: anchor.identifier))
            root.addChild(contentRoot)
            arView.scene.addAnchor(root)
            root.isEnabled = true
        }
        streetLocalizationMode = .visuallyLocalized
        trackingDescription = "Apple geographic anchor locked"
        if acquiredFirstLock {
            resyncCurrentScene()
        }
    }

    private func resyncCurrentScene() {
        sync(
            trains: Array(latestTrains.values),
            selectedID: selectedID,
            headingEstimate: currentHeadingEstimate,
            displayMode: displayMode
        )
    }

    func sync(
        trains: [NearbyTrain],
        selectedID: String?,
        location: CLLocation? = nil,
        headingEstimate: HeadingEstimate = .unavailable,
        relativeAltitudeMeters: Double? = nil,
        displayMode: ARDisplayMode = .street
    ) {
        let previousMode = self.displayMode
        let previousSelectedID = self.selectedID
        self.displayMode = displayMode
        if previousMode != displayMode || (
            displayMode == .arrival && previousSelectedID != selectedID
        ) {
            clearArrivalAlignment()
        }
        if previousMode != displayMode {
            if displayMode == .arrival {
                runArrivalTrackingSession()
            } else {
                isRunning = false
                geoAvailabilityCheckInFlight = false
                if cinematicDemoEnabled {
                    runCinematicDemoSession()
                } else if let coordinate = currentCoordinate ?? location?.coordinate {
                    let altitude = location?.altitude ?? currentAltitudeMeters ?? 0
                    beginBestAvailableStreetSession(at: CLLocation(
                        coordinate: coordinate,
                        altitude: altitude,
                        horizontalAccuracy: location?.horizontalAccuracy ?? 20,
                        verticalAccuracy: location?.verticalAccuracy ?? 50,
                        timestamp: .now
                    ))
                }
            }
        } else if displayMode == .arrival {
            root.transform.matrix = matrix_identity_float4x4
        }
        if let location { currentCoordinate = location.coordinate }
        if let location {
            updateAltitude(
                from: location,
                relativeAltitudeMeters: relativeAltitudeMeters
            )
        }
        currentHeadingEstimate = headingEstimate
        contentRoot.orientation = simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        guard let origin = self.origin ?? currentCoordinate, isRunning else { return }
        latestTrains = Dictionary(uniqueKeysWithValues: trains.map { ($0.id, $0) })
        self.selectedID = selectedID
        if displayMode == .arrival,
           arrivalAligned,
           let selectedID,
           arrivalAlignedSegmentID != latestTrains[selectedID]?.segmentId {
            // An arrival alignment is tied to one station approach. Once the
            // realtime train advances to another segment, the old platform
            // axis no longer describes that arrival and must be re-established.
            clearArrivalAlignment()
        }

        // Street geometry is shown only after ARGeoTracking has established
        // an outdoor visual/geographic lock. There is deliberately no compass
        // or indoor landmark fallback: an unavailable lock must fail closed
        // instead of rendering a convincingly wrong city direction.
        let orientationIsUsable = displayMode == .arrival
            ? arrivalAligned
            : cinematicDemoEnabled
                || (streetLocalizationMode.isPrecise && geoOriginTransform != nil)
        guard orientationIsUsable else {
            root.isEnabled = false
            edgeIndicator = EdgeIndicatorState()
            return
        }
        root.isEnabled = true

        // The API response is a discovery set, not twenty simultaneous AR
        // targets. Rendering every nearby service simultaneously falsely looks
        // like a crowd of trains under one sidewalk. Render only the selected
        // train; the discovery sheet remains available to switch targets.
        let renderTrains = trains.filter { $0.id == selectedID }
        let activeIDs = Set(renderTrains.map(\.id))
        for (id, entity) in markers where !activeIDs.contains(id) {
            entity.removeFromParent()
            markers[id] = nil
            detailedMarkerIDs.remove(id)
            markerYawRadians[id] = nil
            markerSegmentIDs[id] = nil
            visualProgress[id] = nil
            projectedMarkerPaths[id] = nil
        }
        for (id, entity) in overviewRouteEntities where !activeIDs.contains(id) {
            entity.removeFromParent()
            overviewRouteEntities[id] = nil
            overviewRouteSignatures[id] = nil
        }
        if displayMode != .street {
            for entity in overviewRouteEntities.values {
                entity.removeFromParent()
            }
            overviewRouteEntities.removeAll()
            overviewRouteSignatures.removeAll()
        }

        for train in renderTrains {
            updateVisualProgress(for: train)
            if displayMode == .street {
                if train.positionMethod == "cinematic_demo" {
                    if projectedMarkerPaths[train.id] == nil {
                        projectedMarkerPaths[train.id] = cinematicDemoPath(
                            for: train
                        )
                    }
                } else {
                    projectedMarkerPaths[train.id] = projectedStreetPath(
                        for: train,
                        origin: origin
                    )
                }
            } else {
                projectedMarkerPaths[train.id] = nil
            }
            // The selected target is the cinematic focus even when its MTA
            // timing estimate is broad; uncertainty remains explicit in the
            // route band and card rather than degrading it to an abstract box.
            let shouldShowDetail = train.id == selectedID
            let entity: ModelEntity
            if let existing = markers[train.id],
               detailedMarkerIDs.contains(train.id) == shouldShowDetail {
                entity = existing
            } else {
                markers[train.id]?.removeFromParent()
                markerSegmentIDs[train.id] = nil
                markerYawRadians[train.id] = nil
                entity = TrainEntityFactory.makeMarker(
                    for: train,
                    selected: train.id == selectedID,
                    showDetailedModel: shouldShowDetail
                )
                markers[train.id] = entity
                if shouldShowDetail {
                    detailedMarkerIDs.insert(train.id)
                } else {
                    detailedMarkerIDs.remove(train.id)
                }
                contentRoot.addChild(entity)
                let initial = markerEntityPosition(for: train, after: 0)
                entity.position = initial
            }
            entity.position = markerEntityPosition(for: train, after: 0)
            // The 30 Hz clock advances this marker along the exact projected
            // rail polyline. Do not hand RealityKit a straight endpoint chord.
            let geographicDistance = Float(train.distanceFromUserMeters)
            TrainEntityFactory.applyAppearance(
                to: entity,
                train: train,
                selected: train.id == selectedID,
                distanceMeters: geographicDistance,
                lifeSized: displayMode == .arrival
            )
            updateMarkerOrientation(for: train, entity: entity)
            if displayMode == .street {
                updateOverviewRoute(for: train, origin: origin)
            }
        }
        redrawSelectedRoute(origin: origin)
        updateIndicator()
    }

    private func updateOverviewRoute(
        for train: NearbyTrain,
        origin: CLLocationCoordinate2D
    ) {
        let isSelected = train.id == selectedID
        let overviewPoints = train.routeOverview ?? []
        let signature = [
            train.routeShapeId ?? train.id,
            String(overviewPoints.count),
            isSelected ? "selected" : "context",
        ].joined(separator: ":")
        guard overviewRouteSignatures[train.id] != signature else { return }
        overviewRouteEntities[train.id]?.removeFromParent()

        let positions: [SIMD3<Float>]
        if train.positionMethod == "cinematic_demo" {
            positions = projectedMarkerPaths[train.id] ?? []
        } else {
            positions = RouteRenderer.projectedPositions(
                points: overviewPoints,
                origin: origin,
                depthMeters: effectiveVerticalDropMeters(
                    tunnelDepth: train.approximateDepthMeters,
                    targetAltitudeMeters: train.estimatedAltitudeMeters
                )
            )
        }
        let line = RouteRenderer.makeCenterline(
            positions: positions,
            color: UIColor(hex: train.routeColor),
            width: isSelected ? 0.085 : 0.04,
            opacity: isSelected ? 0.62 : 0.22
        )
        contentRoot.addChild(line)
        overviewRouteEntities[train.id] = line
        overviewRouteSignatures[train.id] = signature
    }

    func updateHeadingEstimate(_ estimate: HeadingEstimate) {
        currentHeadingEstimate = estimate
    }

    private func markerPosition(
        for train: NearbyTrain,
        after seconds: TimeInterval
    ) -> SIMD3<Float> {
        let now = ProcessInfo.processInfo.systemUptime
        let progress = visualProgress[train.id]
        let visualChainage = progress?.chainage(at: now + seconds)
        if displayMode == .arrival,
           let axis = arrivalAxisForward,
           let anchor = arrivalAnchorPosition,
           let nextStop = progress?.nextStopChainageMeters
                ?? train.nextStopChainageMeters,
           let visualChainage {
            let distanceToStation = max(0, nextStop - visualChainage)
            let visualDistance = arrivalVisualDistance(
                physicalMeters: distanceToStation
            )
            // `visualDistance` locates the leading end of the train. Keep the
            // consist behind it in the tunnel instead of centering 157 m of
            // cars on the platform/camera.
            return anchor
                + axis * (
                    visualDistance
                        + TrainEntityFactory.physicalConsistLengthMeters / 2
                )
                + SIMD3<Float>(0, Self.arrivalTrackYOffset, 0)
        }
        if let path = projectedMarkerPaths[train.id],
           let position = RouteRenderer.position(
               along: path,
               progress: streetProgress(
                   for: train,
                   visualChainage: visualChainage
               )
           ) {
            return position
        }
        return displayPosition(
            for: train.position,
            depth: train.approximateDepthMeters,
            targetAltitudeMeters: train.estimatedAltitudeMeters
        )
    }

    private func markerEntityPosition(
        for train: NearbyTrain,
        after seconds: TimeInterval
    ) -> SIMD3<Float> {
        let trackPosition = markerPosition(for: train, after: seconds)
        let selected = train.id == selectedID
        let detailed = selected
        let height = TrainEntityFactory.trackVerticalOffset(
            selected: selected,
            showDetailedModel: detailed,
            distanceMeters: Float(train.distanceFromUserMeters),
            lifeSized: displayMode == .arrival
                || (train.positionMethod == "cinematic_demo" && selected)
        )
        return trackPosition + SIMD3<Float>(0, height, 0)
    }

    private func updateVisualProgress(for train: NearbyTrain) {
        guard let incomingMean = train.meanChainageMeters,
              let nextStop = train.nextStopChainageMeters
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let remainingETA = max(0, train.etaTime.timeIntervalSinceNow)
        let mayAdvance = train.transitStatus != "at_station"
        if let previous = visualProgress[train.id],
           previous.segmentID == train.segmentId {
            // Heading/location refreshes often resubmit the identical source
            // observation. Do not retime the animation for those calls.
            let isNewSourceInformation = train.observedAt != previous.sourceObservedAt
                || incomingMean > previous.sourceMeanChainageMeters + 0.25
            guard isNewSourceInformation else { return }
            let monotonicMean = max(previous.chainage(at: now), incomingMean)
            let remaining = max(0, nextStop - monotonicMean)
            let speed = mayAdvance && remainingETA > 0
                ? remaining / remainingETA
                : 0
            visualProgress[train.id] = VisualProgress(
                segmentID: train.segmentId,
                chainageMeters: monotonicMean,
                nextStopChainageMeters: nextStop,
                speedMetersPerSecond: speed,
                updatedAt: now,
                sourceObservedAt: train.observedAt,
                sourceMeanChainageMeters: incomingMean
            )
            return
        }
        let effectiveMean = mayAdvance && remainingETA <= 0
            ? nextStop
            : incomingMean
        let remaining = max(0, nextStop - effectiveMean)
        visualProgress[train.id] = VisualProgress(
            segmentID: train.segmentId,
            chainageMeters: effectiveMean,
            nextStopChainageMeters: nextStop,
            speedMetersPerSecond: mayAdvance && remainingETA > 0
                ? remaining / remainingETA
                : 0,
            updatedAt: now,
            sourceObservedAt: train.observedAt,
            sourceMeanChainageMeters: incomingMean
        )
    }

    private func markerTravelDirection(for train: NearbyTrain) -> SIMD2<Float> {
        if displayMode == .arrival, let axis = arrivalAxisForward {
            // The user points toward the incoming tunnel; the train travels
            // from that direction back toward the platform/camera.
            return SIMD2(-axis.x, -axis.z)
        }
        let visualChainage = visualProgress[train.id]?.chainage(
            at: ProcessInfo.processInfo.systemUptime
        )
        if let path = projectedMarkerPaths[train.id],
           let direction = RouteRenderer.direction(
               along: path,
               progress: streetProgress(
                   for: train,
                   visualChainage: visualChainage
               )
           ) {
            return direction
        }
        return SIMD2<Float>(sin(Float(train.bearingDegrees * .pi / 180)),
                            -cos(Float(train.bearingDegrees * .pi / 180)))
    }

    private func updateMarkerOrientation(
        for train: NearbyTrain,
        entity: ModelEntity
    ) {
        let travel = markerTravelDirection(for: train)
        guard simd_length(travel) > 0.01 else { return }
        var desired = atan2(travel.x, travel.y)
        if let previous = markerYawRadians[train.id] {
            // A rail axis has two equivalent orientations. Pick the one that
            // is closest to the current model yaw so a noisy tangent can never
            // trigger a gratuitous 180-degree spin.
            let reversed = desired + .pi
            let directDelta = abs(shortestYawDelta(from: previous, to: desired))
            let reversedDelta = abs(shortestYawDelta(from: previous, to: reversed))
            if reversedDelta < directDelta { desired = reversed }
            desired = TrainEntityFactory.stabilizedYaw(
                previous: previous,
                desired: desired,
                maximumDelta: .pi / 180
            )
        }
        markerYawRadians[train.id] = desired
        markerSegmentIDs[train.id] = train.segmentId
        entity.orientation = simd_quatf(
            angle: desired,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    private func shortestYawDelta(from start: Float, to end: Float) -> Float {
        let fullTurn = Float.pi * 2
        var delta = (end - start).truncatingRemainder(dividingBy: fullTurn)
        if delta > .pi { delta -= fullTurn }
        if delta < -.pi { delta += fullTurn }
        return delta
    }

    private func streetProgress(
        for train: NearbyTrain,
        visualChainage: Double?
    ) -> Double {
        guard let start = train.meanChainageMeters,
              let end = train.nextStopChainageMeters,
              end > start
        else { return 0 }
        return min(max(((visualChainage ?? start) - start) / (end - start), 0), 1)
    }

    private func projectedStreetPath(
        for train: NearbyTrain,
        origin: CLLocationCoordinate2D
    ) -> [SIMD3<Float>] {
        RouteRenderer.projectedPositions(
            points: TrainMotionPredictor.routeToNextStop(of: train),
            origin: origin,
            depthMeters: effectiveVerticalDropMeters(
                tunnelDepth: train.approximateDepthMeters,
                targetAltitudeMeters: train.estimatedAltitudeMeters
            )
        )
    }

    /// The demo is intentionally a local AR spectacle, not a compressed map.
    /// A life-size rigid consist is longer than the former city-scale route,
    /// so moving it around that short nonlinear curve caused large swings and
    /// apparent spins. Anchor one long, nearly straight track to the camera at
    /// demo start and never recompute it as the user moves.
    private func cinematicDemoPath(for train: NearbyTrain) -> [SIMD3<Float>] {
        guard let frame = arView.session.currentFrame else {
            let y: Float = -14
            // A sync can arrive in the same run-loop turn that resets the AR
            // session, before ARKit publishes its first camera frame. Use the
            // reset session's canonical forward direction (-Z), with the same
            // toward-the-viewer motion as the frame-derived path below. The
            // old fallback began at the camera and moved away, leaving most of
            // a life-size consist behind the viewer.
            return stride(from: Float(0), through: 230, by: 10).map {
                SIMD3<Float>(0, y, -115 + $0)
            }
        }
        let transform = frame.camera.transform
        let camera = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        var forward = SIMD3<Float>(
            -transform.columns.2.x,
            0,
            -transform.columns.2.z
        )
        if simd_length(forward) < 0.001 {
            forward = SIMD3<Float>(0, 0, -1)
        } else {
            forward = simd_normalize(forward)
        }
        var right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        if simd_length(right) < 0.001 {
            right = SIMD3<Float>(1, 0, 0)
        } else {
            right = simd_normalize(right)
        }

        let isSecondTrain = train.line == "D2"
        let lateral: Float = isSecondTrain ? 28 : 0
        // A ten-car A-Division consist is about 157 m including coupler gaps.
        // Begin with its nearest end still tens of metres in front of the
        // viewer, then bring it toward and past the camera. Previously its
        // center began only 15 m away, placing half the train through/behind
        // the viewer and making its apparent scale look absurd.
        let startForward: Float = isSecondTrain ? 145 : 115
        let length: Float = isSecondTrain ? 250 : 230
        let direction = isSecondTrain
            ? simd_normalize(-forward + right * 0.12)
            : -forward
        let start = SIMD3<Float>(camera.x, camera.y - 14, camera.z)
            + forward * startForward
            + right * lateral
        return stride(from: Float(0), through: length, by: 10).map {
            start + direction * $0
        }
    }

    private func advanceMarkers() {
        guard isRunning else { return }
        for (id, entity) in markers {
            guard let train = latestTrains[id] else { continue }
            entity.position = markerEntityPosition(for: train, after: 0)
            updateMarkerOrientation(for: train, entity: entity)
        }
    }

    private func arrivalVisualDistance(physicalMeters: Double) -> Float {
        guard let initial = arrivalInitialDistanceMeters, initial > 0 else {
            return 100
        }
        let remainingFraction = min(max(physicalMeters / initial, 0), 1)
        // The train nose moves linearly through a 95 m visible approach over
        // the realtime ETA. This is intentionally station-centric: it shows
        // arrival progress without claiming exact indoor geographic position.
        return Float(5 + 95 * remainingFraction)
    }

    private func redrawSelectedRoute(origin: CLLocationCoordinate2D) {
        routeEntity?.removeFromParent()
        routeEntity = nil
        guard let selectedID, let train = latestTrains[selectedID] else { return }
        if displayMode == .arrival {
            let arrival = makeArrivalVisualization(for: train)
            contentRoot.addChild(arrival)
            routeEntity = arrival
            return
        }
        let container = Entity()
        container.name = "selected-route"
        let distance = Float(train.distanceFromUserMeters)
        let gauge = TrainEntityFactory.displayedTrackGauge(
            selected: true,
            showDetailedModel: true,
            distanceMeters: distance,
            lifeSized: train.positionMethod == "cinematic_demo"
        )
        let railThickness = TrainEntityFactory.displayedRailThickness(
            selected: true,
            showDetailedModel: true,
            distanceMeters: distance,
            lifeSized: train.positionMethod == "cinematic_demo"
        )
        if train.positionRange.count >= 2 {
            let uncertainty = RouteRenderer.makeRoute(
                points: train.positionRange,
                origin: origin,
                depthMeters: effectiveVerticalDropMeters(
                    tunnelDepth: train.approximateDepthMeters,
                    targetAltitudeMeters: train.estimatedAltitudeMeters
                ),
                color: UIColor(hex: train.routeColor),
                lineWidth: TrainEntityFactory.displayedUncertaintyWidth(
                    selected: true,
                    showDetailedModel: true,
                    distanceMeters: distance,
                    lifeSized: train.positionMethod == "cinematic_demo"
                ),
                opacity: 0.16
            )
            container.addChild(uncertainty)
        }
        let routePositions = projectedMarkerPaths[train.id]
            ?? projectedStreetPath(for: train, origin: origin)
        let route = RouteRenderer.makeRoute(
            positions: routePositions,
            color: UIColor(hex: train.routeColor),
            lineWidth: 0.28,
            opacity: 0.92,
            railGauge: gauge,
            railThickness: railThickness
        )
        container.addChild(route)
        contentRoot.addChild(container)
        routeEntity = container
    }

    private func makeArrivalVisualization(for train: NearbyTrain) -> Entity {
        let container = Entity()
        container.name = "arrival-track"
        guard let axis = arrivalAxisForward, let anchor = arrivalAnchorPosition else {
            return container
        }
        let vertical = SIMD3<Float>(0, Self.arrivalTrackYOffset, 0)
        let trackStart = anchor
            + axis * (115 + TrainEntityFactory.physicalConsistLengthMeters)
            + vertical
        let trackEnd = anchor - axis * 8 + vertical
        var crossTrack = simd_cross(SIMD3<Float>(0, 1, 0), axis)
        if simd_length(crossTrack) < 0.001 {
            crossTrack = SIMD3<Float>(1, 0, 0)
        }
        crossTrack = simd_normalize(crossTrack)
        for offset: Float in [-0.58, 0.58] {
            container.addChild(makeSegment(
                from: trackStart + crossTrack * offset,
                to: trackEnd + crossTrack * offset,
                width: 0.11,
                color: UIColor(white: 0.72, alpha: 0.85)
            ))
        }
        for distance in stride(
            from: Float(-6),
            through: 110 + TrainEntityFactory.physicalConsistLengthMeters,
            by: 3.0
        ) {
            let center = anchor + axis * distance + vertical
            container.addChild(makeSegment(
                from: center - crossTrack * 0.82,
                to: center + crossTrack * 0.82,
                width: 0.09,
                color: UIColor(white: 0.25, alpha: 0.8)
            ))
        }

        if let lower = train.lowerChainageMeters,
           let upper = train.upperChainageMeters,
           let nextStop = train.nextStopChainageMeters {
            let far = arrivalVisualDistance(
                physicalMeters: max(0, nextStop - lower)
            )
            let near = arrivalVisualDistance(
                physicalMeters: max(0, nextStop - upper)
            )
            container.addChild(makeSegment(
                from: anchor + axis * far + vertical,
                to: anchor + axis * near + vertical,
                width: 2.8,
                color: UIColor(hex: train.routeColor).withAlphaComponent(0.24)
            ))
        }
        return container
    }

    private func makeSegment(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        width: Float,
        color: UIColor
    ) -> ModelEntity {
        let delta = end - start
        let rawLength = simd_length(delta)
        let length = max(rawLength, 0.05)
        let segment = ModelEntity(
            mesh: .generateBox(
                size: SIMD3(width, length, width),
                cornerRadius: min(width / 2, 0.4)
            ),
            materials: [SimpleMaterial(
                color: color,
                roughness: 0.35,
                isMetallic: false
            )]
        )
        segment.position = (start + end) / 2
        if rawLength > 0.001 {
            segment.orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(delta)
            )
        }
        return segment
    }

    private func displayPosition(
        for point: GeoPoint,
        depth: Double,
        targetAltitudeMeters: Double?
    ) -> SIMD3<Float> {
        let target = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        // Keep the AR scene tied to the session's initial location. Using each
        // noisy GPS fix as a new origin made stationary trains jump forward and
        // backward inside high-rise buildings.
        let reference = origin ?? currentCoordinate ?? target
        return GeoCoordinateConverter.displayARPosition(
            origin: reference,
            target: target,
            depthMeters: effectiveVerticalDropMeters(
                tunnelDepth: depth,
                targetAltitudeMeters: targetAltitudeMeters
            )
        )
    }

    private func cameraBearingDegrees(from transform: simd_float4x4) -> Double? {
        let forward = SIMD2<Float>(-transform.columns.2.x, -transform.columns.2.z)
        guard simd_length(forward) > 0.001 else { return nil }
        return normalizedDegrees(
            atan2(Double(forward.x), Double(-forward.y)) * 180 / .pi
        )
    }

    private func updateAltitude(
        from location: CLLocation,
        relativeAltitudeMeters: Double?
    ) {
        if let relativeAltitudeMeters, let altitudeReferenceMeters {
            currentAltitudeMeters = altitudeReferenceMeters + relativeAltitudeMeters
            return
        }
        guard location.verticalAccuracy >= 0, location.verticalAccuracy <= 50 else {
            return
        }
        currentAltitudeMeters = location.altitude
        if let relativeAltitudeMeters {
            altitudeReferenceMeters = location.altitude - relativeAltitudeMeters
        }
    }

    private func effectiveVerticalDropMeters(
        tunnelDepth: Double,
        targetAltitudeMeters: Double?
    ) -> Double {
        if displayMode == .arrival {
            // Arrival View is station-centric and uses its manually aligned
            // local track axis rather than approximate tunnel altitude.
            return 0.35
        }
        // Street content is parented to a ground-level ARGeoAnchor. Its local
        // y=0 is therefore the mapped surface, not the phone's altitude. Using
        // the phone altitude here as well double-counted elevation and could
        // put a nominal 15 m tunnel more than 100 m below a high-floor user.
        _ = targetAltitudeMeters
        return tunnelDepth
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: arView)
        var entity = arView.entity(at: location)
        while let current = entity {
            if current.name.hasPrefix("train:") {
                onTrainSelected?(String(current.name.dropFirst("train:".count)))
                return
            }
            entity = current.parent
        }
        // Empty-space taps should not silently remove the only rendered
        // target. Selection changes through the train itself or discovery UI.
    }

    private func updateIndicator() {
        updateTrackingDescription()
        if let frame = arView.session.currentFrame,
           let bearing = cameraBearingDegrees(from: frame.camera.transform) {
            let absoluteBearing = normalizedDegrees(bearing)
            if viewHeadingDegrees.map({
                abs(HeadingEstimator.signedDeltaDegrees(
                    from: $0,
                    to: absoluteBearing
                )) >= 0.25
            }) ?? true {
                viewHeadingDegrees = absoluteBearing
            }
            onCameraOrientationSample?(bearing, frame.timestamp)
        }
        guard let selectedID,
              let train = latestTrains[selectedID],
              let marker = markers[selectedID],
              let frame = arView.session.currentFrame
        else {
            edgeIndicator = EdgeIndicatorState()
            return
        }
        let worldPosition = marker.position(relativeTo: nil)
        let cameraTransform = frame.camera.transform
        let cameraSpace = cameraTransform.inverse
            * SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        let bounds = arView.bounds.insetBy(dx: 30, dy: 60)
        let visualBounds = marker.visualBounds(relativeTo: nil)
        let extrema: [SIMD3<Float>] = [
            worldPosition,
            SIMD3(visualBounds.min.x, visualBounds.min.y, visualBounds.min.z),
            SIMD3(visualBounds.min.x, visualBounds.min.y, visualBounds.max.z),
            SIMD3(visualBounds.min.x, visualBounds.max.y, visualBounds.min.z),
            SIMD3(visualBounds.min.x, visualBounds.max.y, visualBounds.max.z),
            SIMD3(visualBounds.max.x, visualBounds.min.y, visualBounds.min.z),
            SIMD3(visualBounds.max.x, visualBounds.min.y, visualBounds.max.z),
            SIMD3(visualBounds.max.x, visualBounds.max.y, visualBounds.min.z),
            SIMD3(visualBounds.max.x, visualBounds.max.y, visualBounds.max.z),
        ]
        let anyPartIsVisible = extrema.contains { point in
            let pointInCamera = cameraTransform.inverse
                * SIMD4<Float>(point.x, point.y, point.z, 1)
            guard pointInCamera.z < 0, let projected = arView.project(point) else {
                return false
            }
            return bounds.contains(projected)
        }
        let isInFront = cameraSpace.z < 0
        if anyPartIsVisible {
            edgeIndicator = EdgeIndicatorState()
            return
        }
        var x = Double(cameraSpace.x)
        var y = Double(-cameraSpace.y)
        if !isInFront {
            x = -x
            y = -y
        }
        if abs(x) + abs(y) < 0.001 {
            y = -1
        }
        edgeIndicator = EdgeIndicatorState(
            isVisible: true,
            angleRadians: atan2(y, x) + .pi / 2,
            line: train.line,
            color: train.routeColor
        )
    }

    private func updateTrackingDescription() {
        guard let frame = arView.session.currentFrame else { return }
        switch frame.camera.trackingState {
        case .normal:
            if displayMode == .arrival {
                trackingDescription = arrivalAligned
                    ? "Platform track axis locked"
                    : "Platform tracking ready — align incoming track"
                return
            }
            switch streetLocalizationMode {
            case .visuallyLocalized:
                trackingDescription = "Apple geographic anchor locked"
            case .cinematicDemo:
                trackingDescription = "Cinematic demo — simulated route"
            case .visualLocalizing, .checkingAvailability:
                trackingDescription = "Matching the camera view to Apple Maps"
            case .unavailable:
                trackingDescription = "Outdoor visual positioning unavailable"
            }
        case .notAvailable:
            trackingDescription = "AR tracking unavailable"
        case let .limited(reason):
            trackingDescription = "AR tracking limited: \(reason)"
        }
    }
}
