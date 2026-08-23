import Foundation

struct GeoPoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

enum EstimateQuality: String, Codable, Sendable {
    case high
    case medium
    case low
}

enum ARDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case street
    case arrival

    var id: String { rawValue }
    var label: String { self == .street ? "Street" : "Arrival" }
}

struct NearbyTrain: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let line: String
    let routeColor: String
    let textColor: String
    let direction: String
    let previousStation: String?
    let nextStation: String
    var nextStopPosition: GeoPoint? = nil
    let etaSeconds: Int
    let etaTime: Date
    let position: GeoPoint
    let bearingDegrees: Double
    let speedMetersPerSecond: Double
    let distanceFromUserMeters: Double
    let approximateDepthMeters: Double
    var estimatedAltitudeMeters: Double? = nil
    var horizontalUncertaintyMeters: Double? = nil
    var verticalUncertaintyMeters: Double? = nil
    let observedAt: Date
    let validUntil: Date
    let estimateQuality: EstimateQuality
    var positionMethod: String? = nil
    var transitStatus: String? = nil
    var routeShapeId: String? = nil
    var segmentId: String? = nil
    var meanChainageMeters: Double? = nil
    var lowerChainageMeters: Double? = nil
    var upperChainageMeters: Double? = nil
    var nextStopChainageMeters: Double? = nil
    var positionRange: [GeoPoint] = []
    var shapeValidity: String? = nil
    var degradationReason: String? = nil
    let upcomingRoute: [GeoPoint]
    var routeOverview: [GeoPoint]? = nil
}

extension NearbyTrain {
    var destinationLabel: String {
        direction.hasPrefix("Toward ")
            ? String(direction.dropFirst("Toward ".count))
            : direction
    }

    var chainageIntervalMeters: Double? {
        guard let lowerChainageMeters, let upperChainageMeters else { return nil }
        return max(0, upperChainageMeters - lowerChainageMeters)
    }

    var supportsDetailedTrainModel: Bool {
        guard shapeValidity == "matched", let interval = chainageIntervalMeters else {
            return false
        }
        return interval <= 120
    }
}

struct NearbyResponse: Codable, Equatable, Sendable {
    let generatedAt: Date
    let feedAgeSeconds: Double
    let searchRadiusMeters: Double
    var snapshotRevision: String? = nil
    let trains: [NearbyTrain]
}

enum LoadingState: Equatable {
    case locating
    case loading
    case ready
    case empty
    case failed(String)
}

struct EdgeIndicatorState: Equatable {
    var isVisible = false
    var angleRadians: Double = 0
    var line = ""
    var color = "#FFFFFF"
}
