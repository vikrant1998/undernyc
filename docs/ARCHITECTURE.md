# UnderNYC Architecture

UnderNYC deliberately divides responsibility at a narrow uncertainty-aware
geographic API.

```text
MTA static GTFS ─┐
                 ├─ Python subway model ─ /nearby ─ iPhone AR scene
MTA GTFS-RT ─────┘
```

The backend understands trips, service calendars, stop order, station names,
route shapes, realtime feed entities, interpolation, and locality. The iPhone
receives nearby train state along a route: mean chainage, a lower/upper
chainage interval, status, degradation reason, and a short upcoming path. Shape
IDs never imply exact vehicle GPS; they identify the static track model
used for the estimate.

## Backend pipeline

1. The supplemented MTA static feed is streamed into a compact SQLite index.
2. Stops are projected monotonically onto their trip shape because the subway
   feed does not provide `shape_dist_traveled` in `stop_times.txt`.
3. All eight subway GTFS-Realtime feeds are fetched concurrently.
4. TripUpdate and VehiclePosition entities are paired by trip, route, and
   service date. MTA realtime trip suffixes are resolved against the active
   static service.
5. The train is represented as occupancy along the static shape. Its mean is
   estimated from realtime arrival/departure timing and its possible range is
   expressed as lower/upper route chainage.
6. Station-associated trains receive a platform-length range rather than a
   precise point. Reroutes that cannot be reconciled with the static shape are
   rejected rather than drawn on a false path.
7. `/nearby` filters and sorts the snapshot by geodesic user distance and
   carries the source snapshot revision separately from response time. It does
   not advance snapshot geometry; the client evaluates the timestamped motion
   model once, avoiding double extrapolation.

The estimate is intentionally labelled. It is not tunnel telemetry. Vertical
placement is a visualization convention and is never presented as measured
tunnel depth.

## iPhone pipeline

Street mode runs `ARGeoTrackingConfiguration`. After Apple visual geolocation
reaches medium/high accuracy, the app creates a ground-level `ARGeoAnchor` at
the session origin. All literal-scale east/north subway geometry is expressed in
that anchor's east/up/south frame, so GPS/heading is not manually reimplemented
as an assumed world-zero transform.

Platform mode is a different spatial contract and a different AR session. It
uses gravity-only world tracking; the user selects a station, points down the
incoming track once, and taps Align. That local track axis remains authoritative
without relying on indoor magnetic north or outdoor localization imagery.

RealityKit markers move at display rate from route chainage and absolute ETA,
while backend snapshots refresh at a lower cadence. A broad translucent route
segment communicates possible longitudinal occupancy. Only the selected train
is rendered as a detailed consist; its uncertainty remains visible rather than
being implied away. Platform mode renders that train at physical scale along
the aligned local axis, approaching a symbolic platform origin. The selected
entity is projected into screen space to switch mutually exclusively between
its marker and edge arrow.

## Demo limits

- A warm backend and a mostly stationary user are assumed.
- Moving more than 150 metres rebases the outdoor AR session.
- There is no measured tunnel depth model, LiDAR occlusion, navigation,
  persistence, analytics, or user identity.
- MTA outages and missing trip matches fail by omitting the affected train,
  never by inventing a position.
