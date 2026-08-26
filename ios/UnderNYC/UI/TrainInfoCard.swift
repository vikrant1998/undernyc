import SwiftUI

struct TrainInfoCard: View {
    let train: NearbyTrain
    let onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(train.line)
                    .font(.headline.bold())
                    .foregroundStyle(Color(uiColor: UIColor(hex: train.textColor)))
                    .frame(width: 40, height: 40)
                    .background(
                        Color(uiColor: UIColor(hex: train.routeColor)),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toward \(train.destinationLabel)")
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(stationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(etaText(now: now))
                    .font(.subheadline.bold().monospacedDigit())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Color(uiColor: UIColor(hex: train.routeColor)).opacity(0.22),
                        in: Capsule()
                    )
                Button(action: onClose) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose another train")
            }
            HStack(spacing: 12) {
                Label(distanceText, systemImage: "location.fill")
                Label(estimateLabel, systemImage: estimateSymbol)
                if let uncertaintyText {
                    Label(uncertaintyText, systemImage: "arrow.left.and.right")
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text(
                train.positionMethod == "cinematic_demo"
                    ? "Simulated route and timing · not MTA data"
                    : "Illustrative AR depth · live MTA timing estimate"
            )
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color(uiColor: UIColor(hex: train.routeColor)))
                .frame(width: 4)
                .padding(.vertical, 10)
        }
    }

    private func etaText(now: Date) -> String {
        let seconds = max(0, Int(train.etaTime.timeIntervalSince(now)))
        if seconds < 60 { return "<1 min" }
        return "\(max(1, seconds / 60)) min"
    }

    private var distanceText: String {
        if train.distanceFromUserMeters < 1000 {
            return "\(Int(train.distanceFromUserMeters)) m"
        }
        return String(format: "%.1f km", train.distanceFromUserMeters / 1000)
    }

    private var stationStatus: String {
        if train.transitStatus == "at_station" {
            if let station = train.previousStation {
                return "Stopped at \(station) · Next \(train.nextStation)"
            }
            return "Stopped at station · Next \(train.nextStation)"
        }
        if let previous = train.previousStation {
            return "\(previous) → \(train.nextStation)"
        }
        return "Approaching \(train.nextStation)"
    }

    private var estimateLabel: String {
        if train.positionMethod == "cinematic_demo" { return "Demo" }
        return train.transitStatus == "at_station" ? "At station" : "Estimated"
    }

    private var estimateSymbol: String {
        train.transitStatus == "at_station" ? "tram.fill" : "waveform.path"
    }

    private var uncertaintyText: String? {
        if let interval = train.chainageIntervalMeters {
            return "~\(Int(interval.rounded())) m range"
        }
        if let horizontal = train.horizontalUncertaintyMeters {
            return "±\(Int(horizontal.rounded())) m"
        }
        return nil
    }
}
