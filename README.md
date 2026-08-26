# UnderNYC

UnderNYC is a native iPhone AR research demo for VRST. Point an iPhone around
New York City to see uncertainty-aware estimates of currently operating subway
trains beneath nearby streets. Tap a train to inspect its destination, next
station, ETA, and possible range along the route; turn away to follow it with
an edge indicator.

This repository contains:

- `backend/`: Python 3.12, FastAPI, static MTA GTFS, and live GTFS-Realtime.
- `ios/`: SwiftUI, ARKit, RealityKit, and Core Location for iOS 17+.
- `render.yaml`: a small hosted HTTPS backend deployment.

The backend owns all subway semantics. The app receives only nearby moving
positions and short geographic paths.

## Backend locally

```bash
cd backend
python3.12 -m venv .venv
.venv/bin/pip install -e '.[dev]'
.venv/bin/pytest -q
.venv/bin/uvicorn undernyc_backend.app:app --reload
```

The first start downloads the current MTA static subway feed and builds the
SQLite index. Test the API near Times Square:

```bash
curl 'http://127.0.0.1:8000/nearby?lat=40.7580&lon=-73.9855'
```

## Render HTTPS backend

1. Push this project to a Git repository.
2. In Render, create a Blueprint from `render.yaml`.
3. Wait for `/ready` to return HTTP 200 (`/health` remains available for
   startup diagnostics).
4. Keep or prewarm the service during a live demonstration; free-tier cold
   starts are outside the 2–3 second interaction target.
5. Copy the generated HTTPS URL into `ios/Config.xcconfig`.

The current MTA subway endpoints do not require an API key. Every endpoint is
overridable through environment variables if MTA changes its URLs.

## iPhone

Requirements:

- Full Xcode with its license accepted
- XcodeGen (`brew install xcodegen`)
- A physical iPhone running iOS 17 or newer
- An Apple development team selected for local signing

Generate and open the project:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license
cd ios
xcodegen generate
open UnderNYC.xcodeproj
```

Select the `UnderNYC` target, choose your signing team, connect the iPhone, and
run. Grant camera and precise location access. Street mode uses Apple's outdoor
visual geolocation and a ground-level geographic anchor; it does not ask for a
manual compass calibration.

## Demo checklist

1. Prewarm `/ready` and confirm fresh live trains.
2. Stand outside with a useful GPS fix near subway service.
3. Launch UnderNYC and wait for “Apple geographic anchor locked.”
4. Use the train picker to choose the live service you want to inspect.
5. For a station demo, switch to **Platform**, choose the station and an
   approaching train, point toward the incoming tunnel, and tap **Align incoming
   track**. Use **Flip 180°** if needed.
6. Compare its next-station ETA with an MTA arrival display.
7. Turn away to show the edge arrow, then turn back to reacquire the train.

## Data and accuracy

Static and realtime data come from the [MTA developer feeds](https://www.mta.info/developers).
Train locations are route-constrained timing estimates between station events,
not exact vehicle telemetry. The translucent route capsule is the possible
along-track range. The selected detailed train is an illustrative focus inside
that range, not a claim of exact vehicle occupancy. Vertical placement is an
illustrative depth below the mapped surface and is not measured tunnel depth.

Street mode fails closed until `ARGeoTrackingConfiguration` and a tracked
`ARGeoAnchor` establish the map-to-camera transform. Platform mode deliberately
uses a separate gravity-only AR session and a one-tap local track axis because
Apple visual geolocation is outdoor-only. Core Motion heading fusion remains a
diagnostic signal, not a second renderer rotation. See
[`docs/HEADING_FUSION.md`](docs/HEADING_FUSION.md).
