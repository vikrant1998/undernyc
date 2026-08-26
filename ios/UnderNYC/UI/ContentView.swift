import ARKit
import CoreLocation
import SwiftUI

struct ContentView: View {
    @StateObject private var locationService = LocationService()
    @StateObject private var headingFusion = HeadingFusionService()
    @StateObject private var trainStore = TrainStore()
    @StateObject private var sceneController = ARSceneController()
    @State private var showDiagnostics = false
    @State private var displayMode: ARDisplayMode = .street
    @State private var showTrainFilters = false
    @State private var cinematicDemoEnabled = true

    var body: some View {
        ZStack {
            ARViewContainer(controller: sceneController)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.48), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 190)
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.52)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 250)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()

            VStack(spacing: 8) {
                HeaderView(
                    store: trainStore,
                    showDiagnostics: $showDiagnostics,
                    showFilters: $showTrainFilters,
                    cinematicDemoEnabled: cinematicDemoEnabled,
                    toggleDemo: { setCinematicDemo(!cinematicDemoEnabled) }
                )
                if displayMode == .street {
                    streetLocalizationStatus
                } else {
                    arrivalAlignmentStatus
                }
                Spacer()
                statusOverlay
                if let selected = trainStore.selectedTrain {
                    TrainInfoCard(train: selected) {
                        trainStore.select(nil)
                    }
                } else {
                    Text("Tap a glowing train to follow it")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()

            if displayMode == .street,
               sceneController.edgeIndicator.isVisible,
               let direction = compassDirection {
                CompassArrow(
                    line: direction.train.line,
                    color: direction.train.routeColor,
                    deltaDegrees: direction.delta
                )
                    .allowsHitTesting(false)
            }
        }
        .task { await runLiveLoop() }
        .onAppear {
            headingFusion.start()
            sceneController.onTrainSelected = { id in
                trainStore.select(id)
            }
            sceneController.onCameraOrientationSample = { bearing, timestamp in
                headingFusion.ingestARCameraBearing(
                    bearing,
                    timestamp: timestamp,
                    heading: locationService.heading,
                    location: locationService.location
                )
                sceneController.updateHeadingEstimate(headingFusion.estimate)
            }
        }
        .onDisappear { headingFusion.stop() }
        .onChange(of: trainStore.selectedTrainID) { _, selectedID in
            sceneController.sync(
                trains: trainStore.trains,
                selectedID: selectedID,
                location: locationService.location,
                headingEstimate: headingFusion.estimate,
                relativeAltitudeMeters: headingFusion.relativeAltitudeMeters,
                displayMode: displayMode
            )
        }
        .onChange(of: trainStore.trains) { _, trains in
            sceneController.sync(
                trains: trains,
                selectedID: trainStore.selectedTrainID,
                location: locationService.location,
                headingEstimate: headingFusion.estimate,
                relativeAltitudeMeters: headingFusion.relativeAltitudeMeters,
                displayMode: displayMode
            )
        }
        .onChange(of: displayMode) { _, mode in
            sceneController.sync(
                trains: trainStore.trains,
                selectedID: trainStore.selectedTrainID,
                location: locationService.location,
                headingEstimate: headingFusion.estimate,
                relativeAltitudeMeters: headingFusion.relativeAltitudeMeters,
                displayMode: mode
            )
        }
        .sheet(isPresented: $showTrainFilters) {
            TrainDiscoveryPanel(
                store: trainStore,
                displayMode: $displayMode,
                onCollapse: { showTrainFilters = false }
            )
            .padding()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDiagnostics) {
            ScrollView {
                DebugOverlay(
                    locationService: locationService,
                    headingFusion: headingFusion,
                    trainStore: trainStore,
                    trackingDescription: sceneController.trackingDescription
                )
                .padding()
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch trainStore.loadingState {
        case .locating:
            StatusPill(text: "Finding your location and heading", symbol: "location")
        case .loading:
            StatusPill(text: "Finding live trains", symbol: "tram.fill")
        case .empty:
            StatusPill(
                text: trainStore.searchText.isEmpty
                    ? "No live subway trains within 5 km"
                    : "No nearby trains match \(trainStore.searchText)",
                symbol: "tram"
            )
        case let .failed(message):
            StatusPill(text: message, symbol: "exclamationmark.triangle.fill")
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var streetLocalizationStatus: some View {
        switch sceneController.streetLocalizationMode {
        case .checkingAvailability:
            StatusPill(
                text: "Checking precise outdoor positioning",
                symbol: "location.magnifyingglass"
            )
        case .visualLocalizing:
            StatusPill(text: "Matching nearby streets", symbol: "viewfinder")
        case .visuallyLocalized:
            HStack(spacing: 8) {
                Label("Visual location locked", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Button("Preview demo") { setCinematicDemo(true) }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .cinematicDemo:
            HStack(spacing: 8) {
                Label("CINEMATIC DEMO · NOT LIVE", systemImage: "film.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                Spacer()
                Button("Use Live") { setCinematicDemo(false) }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .unavailable:
            HStack(spacing: 8) {
                Label(
                    "Outdoor visual positioning unavailable",
                    systemImage: "sun.max.trianglebadge.exclamationmark"
                )
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Button("Retry") {
                    sceneController.retryAutomaticStreetLocalization()
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var arrivalAlignmentStatus: some View {
        if trainStore.selectedTrain == nil {
            StatusPill(
                text: "Choose a train before aligning Arrival View",
                symbol: "tram.fill"
            )
        } else if sceneController.arrivalAligned {
            HStack(spacing: 8) {
                Label("Arrival axis locked", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Button("Flip 180°") { sceneController.flipArrivalAlignment() }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                Button("Realign") { sceneController.clearArrivalAlignment() }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 8) {
                Text("Point down the track toward the tunnel the train will arrive from.")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button {
                    sceneController.alignArrivalView()
                } label: {
                    Label("Align incoming track", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func runLiveLoop() async {
        locationService.start()
        while !Task.isCancelled {
            // ARKit performs the phone's fused true-north alignment. Do not
            // block all live content on a second compass-quality threshold.
            guard locationService.isLocationReady,
                  let location = locationService.location else {
                trainStore.loadingState = .locating
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }
            if cinematicDemoEnabled {
                sceneController.setCinematicDemoEnabled(true, at: location)
                trainStore.setCinematicDemoEnabled(
                    true,
                    at: location.coordinate
                )
            } else {
                sceneController.start(at: location)
            }
            await trainStore.refresh(at: location.coordinate)
            sceneController.sync(
                trains: trainStore.trains,
                selectedID: trainStore.selectedTrainID,
                location: location,
                headingEstimate: headingFusion.estimate,
                relativeAltitudeMeters: headingFusion.relativeAltitudeMeters,
                displayMode: displayMode
            )
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private var compassDirection: (train: NearbyTrain, delta: Double)? {
        guard let train = trainStore.selectedTrain ?? trainStore.trains.first,
              let location = locationService.location,
              let heading = effectiveViewHeading
        else { return nil }
        let bearing = GeoCoordinateConverter.bearingDegrees(
            from: location.coordinate,
            to: CLLocationCoordinate2D(
                latitude: train.position.latitude,
                longitude: train.position.longitude
            )
        )
        return (
            train,
            GeoCoordinateConverter.signedHeadingDeltaDegrees(
                from: heading, to: bearing
            )
        )
    }

    private var effectiveViewHeading: Double? {
        sceneController.viewHeadingDegrees
    }

    private func setCinematicDemo(_ enabled: Bool) {
        guard let location = locationService.location else { return }
        cinematicDemoEnabled = enabled
        trainStore.setCinematicDemoEnabled(enabled, at: location.coordinate)
        sceneController.setCinematicDemoEnabled(enabled, at: location)
        sceneController.sync(
            trains: trainStore.trains,
            selectedID: trainStore.selectedTrainID,
            location: location,
            headingEstimate: headingFusion.estimate,
            relativeAltitudeMeters: headingFusion.relativeAltitudeMeters,
            displayMode: displayMode
        )
    }
}

private struct HeaderView: View {
    @ObservedObject var store: TrainStore
    @Binding var showDiagnostics: Bool
    @Binding var showFilters: Bool
    let cinematicDemoEnabled: Bool
    let toggleDemo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("UnderNYC")
                    .font(.title3.bold())
                Text(
                    store.isCinematicDemoEnabled
                        ? "2 simulated trains"
                        : store.selectedTrain == nil
                        ? "\(store.allNearbyTrains.count) live nearby"
                        : "Tracking 1 of \(store.allNearbyTrains.count) nearby"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggleDemo) {
                Label(
                    cinematicDemoEnabled ? "Live" : "Demo",
                    systemImage: cinematicDemoEnabled
                        ? "dot.radiowaves.left.and.right"
                        : "film"
                )
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                cinematicDemoEnabled
                    ? "Switch to live trains"
                    : "Switch to cinematic demo"
            )
            Button {
                showFilters = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(store.selectedLine ?? "All")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find and filter trains")
            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.body)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle diagnostics")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .stroke(.white.opacity(0.12), lineWidth: 0.75)
        }
    }
}

private struct TrainDiscoveryPanel: View {
    @ObservedObject var store: TrainStore
    @Binding var displayMode: ARDisplayMode
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Discover nearby service")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Done", action: onCollapse)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Line, destination, or station", text: $store.searchText)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if hasFilters {
                    Button("Clear") { store.clearFilters() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    FilterChip(title: "All", selected: store.selectedLine == nil) {
                        store.selectLine(nil)
                    }
                    ForEach(store.availableLines, id: \.line) { train in
                        RouteChip(train: train, selected: store.selectedLine == train.line) {
                            store.selectLine(train.line)
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    FilterChip(title: "Any destination", selected: store.selectedDestination == nil) {
                        store.selectDestination(nil)
                    }
                    ForEach(store.availableDestinations, id: \.self) { destination in
                        FilterChip(
                            title: "Toward \(destination)",
                            symbol: "arrow.forward",
                            selected: store.selectedDestination == destination
                        ) {
                            store.selectDestination(destination)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Button("Any nearby station") { store.selectStation(nil) }
                    ForEach(store.availableStations, id: \.self) { station in
                        Button(station) { store.selectStation(station) }
                    }
                } label: {
                    Label(store.selectedStation ?? "Choose station", systemImage: "building.2")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)

                if store.selectedStation != nil {
                    Button {
                        store.setArrivalsOnly(!store.arrivalsOnly)
                    } label: {
                        Label("Approaching", systemImage: "arrow.forward.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.arrivalsOnly ? .green : .gray)
                }

                Spacer(minLength: 0)

                Picker("AR mode", selection: $displayMode) {
                    ForEach(ARDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var hasFilters: Bool {
        !store.searchText.isEmpty || store.selectedLine != nil
            || store.selectedDestination != nil || store.selectedStation != nil
    }
}

private struct FilterChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .tint(selected ? .blue : .gray.opacity(0.55))
    }
}

private struct RouteChip: View {
    let train: NearbyTrain
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(train.line)
                .font(.caption.bold())
                .frame(minWidth: 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(uiColor: UIColor(hex: train.routeColor)).opacity(selected ? 1 : 0.58))
        .accessibilityLabel("Track line \(train.line)")
    }
}

private struct StatusPill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
