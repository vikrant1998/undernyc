import CoreLocation
import SwiftUI

struct DebugOverlay: View {
    @ObservedObject var locationService: LocationService
    @ObservedObject var headingFusion: HeadingFusionService
    @ObservedObject var trainStore: TrainStore
    let trackingDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trackingDescription)
            if let location = locationService.location {
                Text("Location ±\(Int(location.horizontalAccuracy)) m")
                Text(String(
                    format: "%.5f, %.5f",
                    location.coordinate.latitude,
                    location.coordinate.longitude
                ))
                if location.verticalAccuracy >= 0 {
                    Text("Altitude \(Int(location.altitude.rounded())) m ±\(Int(location.verticalAccuracy.rounded())) m")
                } else {
                    Text("Altitude unavailable")
                }
            }
            if let heading = locationService.heading {
                Text("True heading \(Int(heading.trueHeading))° ±\(Int(heading.headingAccuracy))°")
            }
            if let smoothed = locationService.smoothedTrueHeading {
                Text("Raw smoothed heading \(Int(smoothed.rounded()))°")
            }
            if let fused = headingFusion.estimate.cameraHeadingDegrees {
                Text("Fused heading \(Int(fused.rounded()))° ±\(Int(headingFusion.estimate.standardDeviationDegrees.rounded()))°")
            }
            Text("Magnetic quality \(headingFusion.magneticQuality)")
            if let field = headingFusion.magneticFieldMicrotesla {
                Text(String(format: "Magnetic field %.1f µT", field))
            }
            if let train = trainStore.trains.first,
               let location = locationService.location {
                let bearing = GeoCoordinateConverter.bearingDegrees(
                    from: location.coordinate,
                    to: CLLocationCoordinate2D(
                        latitude: train.position.latitude,
                        longitude: train.position.longitude
                    )
                )
                Text("Nearest \(train.line): bearing \(Int(bearing.rounded()))°, \(Int(train.distanceFromUserMeters)) m")
            }
            Text("Feed age \(Int(trainStore.feedAgeSeconds)) s")
            if let generated = trainStore.generatedAt {
                Text(generated, style: .relative)
            }
        }
        .font(.caption2.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
}
