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
3. Wait for `/health` to report `status: ok`.
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
run. Grant camera and location access. For the best heading lock, move the
iPhone in a small figure eight before the demo.

## Demo checklist

1. Prewarm `/health` and confirm fresh live trains.
2. Stand outside with a useful GPS fix near subway service.
3. Launch UnderNYC and wait for “AR tracking normal.”
4. Tap a glowing line-colored train.
5. For an indoor/station demo, switch to **Arrival**, point toward the incoming
   tunnel, and tap **Align incoming track**. Use **Flip 180°** if needed.
6. Compare its next-station ETA with an MTA arrival display.
7. Turn away to show the edge arrow, then turn back to reacquire the train.

## Data and accuracy

Static and realtime data come from the [MTA developer feeds](https://www.mta.info/developers).
Train locations are route-constrained timing estimates between station events,
not exact vehicle telemetry. The translucent route capsule is the possible
along-track range; a detailed train is withheld when that range is too broad.
Vertical placement is illustrative and not a measured tunnel depth.
The iPhone uses landmark-free heading fusion: a five-second rotation estimates
true north from Core Motion/Core Location observations, then ARKit maintains
relative orientation. If the resulting yaw uncertainty is too high, precise AR
markers are hidden instead of being displayed at a misleading bearing. See
[`docs/HEADING_FUSION.md`](docs/HEADING_FUSION.md).
