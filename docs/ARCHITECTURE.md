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
   carries the source snapshot revision separately from response time.

The estimate is intentionally labelled. It is not tunnel telemetry. Vertical
placement is a visualization convention and is never presented as measured
tunnel depth.

## iPhone pipeline

ARKit runs with gravity alignment. Street View fuses outdoor absolute heading
with ARKit's stable relative pose, then converts each latitude/longitude to a
compressed local east/north displacement. Arrival View is a different spatial
contract: the user points down the incoming track once and taps Align, making
that local track axis authoritative without relying on subway-station magnetic
north.

RealityKit markers move continuously toward a short-horizon prediction between
HTTP refreshes. A broad translucent route segment communicates possible
longitudinal occupancy. A detailed consist is shown only for a selected train
whose matched interval is narrow enough; otherwise the marker becomes an
abstract pulse. Arrival View renders one selected train along the aligned local
axis, approaching a symbolic platform origin. The selected entity is projected
into screen space to switch between its marker and the edge arrow.

## Demo limits

- A warm backend and a mostly stationary user are assumed.
- Moving more than 30 metres rebases the AR session.
- There is no tunnel depth model, LiDAR occlusion, ARGeoAnchor, navigation,
  persistence, analytics, or user identity.
- MTA outages and missing trip matches fail by omitting the affected train,
  never by inventing a position.
