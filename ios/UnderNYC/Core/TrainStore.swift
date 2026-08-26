import CoreLocation
import Foundation

@MainActor
final class TrainStore: ObservableObject {
    @Published private(set) var trains: [NearbyTrain] = []
    @Published private(set) var allNearbyTrains: [NearbyTrain] = []
    @Published private(set) var generatedAt: Date?
    @Published private(set) var feedAgeSeconds: Double = 0
    @Published var loadingState: LoadingState = .locating
    @Published var selectedTrainID: String?
    @Published var searchText = "" {
        didSet { applyFilters(forceNearestSelection: true) }
    }
    @Published private(set) var selectedLine: String?
    @Published private(set) var selectedDestination: String?
    @Published private(set) var selectedStation: String?
    @Published private(set) var arrivalsOnly = false
    @Published private(set) var isCinematicDemoEnabled = false
    @Published private(set) var lastRefreshError: String?

    private let client: APIClient
    private var demoStartedAt = Date()
    private var demoCycle = 0
    private var hasAppliedDefaultLiveLine = false
    private var refreshSerial = 0

    init(client: APIClient = APIClient()) {
        self.client = client
    }

    var selectedTrain: NearbyTrain? {
        trains.first { $0.id == selectedTrainID }
    }

    var availableLines: [NearbyTrain] {
        var seen = Set<String>()
        return allNearbyTrains.filter { seen.insert($0.line).inserted }
    }

    var availableDestinations: [String] {
        let source = selectedLine.map { line in
            allNearbyTrains.filter { $0.line == line }
        } ?? allNearbyTrains
        var seen = Set<String>()
        return source.map(\.destinationLabel).filter { seen.insert($0).inserted }
    }

    var availableStations: [String] {
        var source = allNearbyTrains
        if let selectedLine { source = source.filter { $0.line == selectedLine } }
        if let selectedDestination {
            source = source.filter { $0.destinationLabel == selectedDestination }
        }
        var seen = Set<String>()
        var result: [String] = []
        for train in source {
            for station in [train.nextStation, train.previousStation].compactMap({ $0 }) {
                if seen.insert(station).inserted { result.append(station) }
            }
        }
        return result
    }

    func refresh(at coordinate: CLLocationCoordinate2D) async {
        if isCinematicDemoEnabled {
            refreshCinematicDemo(at: coordinate)
            return
        }
        refreshSerial += 1
        let requestSerial = refreshSerial
        if trains.isEmpty { loadingState = .loading }
        do {
            let response = try await client.nearby(location: coordinate)
            guard requestSerial == refreshSerial, !isCinematicDemoEnabled else {
                return
            }
            allNearbyTrains = Array(
                response.trains.prefix(AppConfiguration.maximumVisibleTrains)
            )
            if !hasAppliedDefaultLiveLine {
                hasAppliedDefaultLiveLine = true
                if allNearbyTrains.contains(where: { $0.line == "1" }) {
                    selectedLine = "1"
                }
            }
            applyFilters(forceNearestSelection: false)
            generatedAt = response.generatedAt
            feedAgeSeconds = response.feedAgeSeconds
            lastRefreshError = nil
            loadingState = trains.isEmpty ? .empty : .ready
        } catch {
            guard requestSerial == refreshSerial, !isCinematicDemoEnabled else {
                return
            }
            lastRefreshError = error.localizedDescription
            // A temporary host wake-up or network failure must not erase a
            // valid visualization. Keep animating the timestamped last-known
            // snapshot and surface the problem in diagnostics.
            if allNearbyTrains.isEmpty
                || allNearbyTrains.allSatisfy({ $0.validUntil <= .now }) {
                allNearbyTrains = []
                trains = []
                selectedTrainID = nil
                loadingState = .failed(error.localizedDescription)
            } else {
                loadingState = .ready
            }
        }
    }

    func select(_ id: String?) {
        selectedTrainID = id
    }

    func setCinematicDemoEnabled(
        _ enabled: Bool,
        at coordinate: CLLocationCoordinate2D
    ) {
        guard isCinematicDemoEnabled != enabled else { return }
        // Invalidate any HTTP response that was started under the old mode.
        refreshSerial += 1
        isCinematicDemoEnabled = enabled
        if enabled {
            demoStartedAt = .now
            demoCycle += 1
            clearFilters()
            refreshCinematicDemo(at: coordinate)
        } else {
            hasAppliedDefaultLiveLine = false
            allNearbyTrains = []
            trains = []
            selectedTrainID = nil
            loadingState = .loading
            lastRefreshError = nil
        }
    }

    func selectLine(_ line: String?) {
        selectedLine = line
        if let selectedDestination,
           !availableDestinations.contains(selectedDestination) {
            self.selectedDestination = nil
        }
        selectedStation = nil
        arrivalsOnly = false
        applyFilters(forceNearestSelection: true)
    }

    func selectDestination(_ destination: String?) {
        selectedDestination = destination
        selectedStation = nil
        arrivalsOnly = false
        applyFilters(forceNearestSelection: true)
    }

    func selectStation(_ station: String?) {
        selectedStation = station
        arrivalsOnly = station != nil
        applyFilters(forceNearestSelection: true)
    }

    func setArrivalsOnly(_ value: Bool) {
        arrivalsOnly = selectedStation == nil ? false : value
        applyFilters(forceNearestSelection: true)
    }

    func clearFilters() {
        searchText = ""
        selectedLine = nil
        selectedDestination = nil
        selectedStation = nil
        arrivalsOnly = false
        applyFilters(forceNearestSelection: true)
    }

    private func applyFilters(forceNearestSelection: Bool) {
        var results = allNearbyTrains
        if let selectedLine { results = results.filter { $0.line == selectedLine } }
        if let selectedDestination {
            results = results.filter { $0.destinationLabel == selectedDestination }
        }
        if let selectedStation {
            results = results.filter { train in
                if arrivalsOnly { return train.nextStation == selectedStation }
                return train.nextStation == selectedStation
                    || train.previousStation == selectedStation
            }
        }

        let query = normalized(searchText)
        if !query.isEmpty {
            let exactLineMatches = results.filter { normalized($0.line) == query }
            if !exactLineMatches.isEmpty {
                results = exactLineMatches
            } else {
                results = results.filter { train in
                    normalized(
                        [
                            train.line,
                            train.direction,
                            train.destinationLabel,
                            train.previousStation ?? "",
                            train.nextStation,
                        ].joined(separator: " ")
                    ).contains(query)
                }
            }
        }

        trains = results
        if !allNearbyTrains.isEmpty {
            loadingState = trains.isEmpty ? .empty : .ready
        }
        let selectionIsVisible = selectedTrainID.map { id in
            results.contains { $0.id == id }
        } ?? false
        if forceNearestSelection || !selectionIsVisible {
            selectedTrainID = results.first?.id
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func refreshCinematicDemo(at userCoordinate: CLLocationCoordinate2D) {
        if Date().timeIntervalSince(demoStartedAt) > 80 {
            demoStartedAt = .now
            demoCycle += 1
        }
        let parkLane = GeoPoint(latitude: 40.7309, longitude: -74.0303)
        let worldTrade = GeoPoint(latitude: 40.712743, longitude: -74.013379)
        let empireState = GeoPoint(latitude: 40.748441, longitude: -73.985664)

        let firstRoute = demoRoute(
            from: parkLane,
            through: GeoPoint(latitude: 40.7198, longitude: -74.0242),
            to: worldTrade
        )
        let secondRoute = demoRoute(
            from: worldTrade,
            through: GeoPoint(latitude: 40.7280, longitude: -74.0025),
            to: empireState
        )
        let first = demoTrain(
            id: "cinematic-park-wtc",
            line: "D1",
            color: "#00D8FF",
            start: parkLane,
            route: firstRoute,
            previous: "25 Park Lane South",
            next: "World Trade Center",
            etaSeconds: 48,
            userCoordinate: userCoordinate
        )
        let second = demoTrain(
            id: "cinematic-wtc-empire",
            line: "D2",
            color: "#FF3B81",
            start: worldTrade,
            route: secondRoute,
            previous: "World Trade Center",
            next: "Empire State Building",
            etaSeconds: 72,
            userCoordinate: userCoordinate
        )
        allNearbyTrains = [first, second]
        trains = allNearbyTrains
        selectedTrainID = selectedTrainID.flatMap { selected in
            trains.contains { $0.id == selected } ? selected : nil
        } ?? first.id
        generatedAt = .now
        feedAgeSeconds = 0
        loadingState = .ready
    }

    private func demoTrain(
        id: String,
        line: String,
        color: String,
        start: GeoPoint,
        route: [GeoPoint],
        previous: String,
        next: String,
        etaSeconds: Int,
        userCoordinate: CLLocationCoordinate2D
    ) -> NearbyTrain {
        let distance = routeDistance(from: start, through: route)
        let firstTarget = route.first ?? start
        let bearing = GeoCoordinateConverter.bearingDegrees(
            from: CLLocationCoordinate2D(
                latitude: start.latitude,
                longitude: start.longitude
            ),
            to: CLLocationCoordinate2D(
                latitude: firstTarget.latitude,
                longitude: firstTarget.longitude
            )
        )
        let userDistance = GeoCoordinateConverter.distanceMeters(
            from: userCoordinate,
            to: CLLocationCoordinate2D(
                latitude: start.latitude,
                longitude: start.longitude
            )
        )
        return NearbyTrain(
            id: id,
            line: line,
            routeColor: color,
            textColor: "#FFFFFF",
            direction: "Toward \(next)",
            previousStation: previous,
            nextStation: next,
            nextStopPosition: route.last,
            etaSeconds: etaSeconds,
            etaTime: demoStartedAt.addingTimeInterval(TimeInterval(etaSeconds)),
            position: start,
            bearingDegrees: bearing,
            speedMetersPerSecond: distance / Double(etaSeconds),
            distanceFromUserMeters: userDistance,
            approximateDepthMeters: 14,
            estimatedAltitudeMeters: 0,
            horizontalUncertaintyMeters: 3,
            verticalUncertaintyMeters: 2,
            observedAt: demoStartedAt,
            validUntil: demoStartedAt.addingTimeInterval(80),
            estimateQuality: .high,
            positionMethod: "cinematic_demo",
            transitStatus: "demo",
            routeShapeId: "cinematic-route-\(line)",
            segmentId: "cinematic-\(line)-\(demoCycle)",
            meanChainageMeters: 0,
            lowerChainageMeters: 0,
            upperChainageMeters: 8,
            nextStopChainageMeters: distance,
            positionRange: [start],
            shapeValidity: "matched",
            degradationReason: nil,
            upcomingRoute: route,
            routeOverview: [start] + route
        )
    }

    private func demoRoute(
        from start: GeoPoint,
        through control: GeoPoint,
        to end: GeoPoint
    ) -> [GeoPoint] {
        (1...28).map { index in
            let t = Double(index) / 28
            let inverse = 1 - t
            return GeoPoint(
                latitude: inverse * inverse * start.latitude
                    + 2 * inverse * t * control.latitude
                    + t * t * end.latitude,
                longitude: inverse * inverse * start.longitude
                    + 2 * inverse * t * control.longitude
                    + t * t * end.longitude
            )
        }
    }

    private func routeDistance(from start: GeoPoint, through route: [GeoPoint]) -> Double {
        var total = 0.0
        var previous = start
        for point in route {
            total += TrainMotionPredictor.meters(from: previous, to: point)
            previous = point
        }
        return total
    }
}
