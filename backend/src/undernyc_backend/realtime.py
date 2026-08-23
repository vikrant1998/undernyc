from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import httpx
from google.transit import gtfs_realtime_pb2

from .config import Settings
from .geometry import interpolate_shape, simplify_path
from .models import EstimateQuality, GeoPoint, NearbyTrain
from .static_gtfs import StopOnTrip, StaticGTFSStore, TripContext

NYC_TIMEZONE = ZoneInfo("America/New_York")


@dataclass
class RealtimeTrip:
    trip_id: str
    route_id: str
    service_date: date
    start_date: str
    trip_update: Any | None = None
    vehicle: Any | None = None
    feed_timestamp: int = 0
    source_index: int = 0


@dataclass(frozen=True)
class RealtimeSnapshot:
    generated_at: datetime
    trains: tuple[NearbyTrain, ...]
    source_successes: int
    source_failures: int
    errors: tuple[str, ...] = field(default_factory=tuple)


def _trip_key(trip: Any, fallback_date: date) -> tuple[str, str, date, str] | None:
    descriptor = trip.trip
    trip_id = descriptor.trip_id
    route_id = descriptor.route_id
    if not trip_id or not route_id:
        return None
    start_date = descriptor.start_date
    try:
        service_date = datetime.strptime(start_date, "%Y%m%d").date()
    except (TypeError, ValueError):
        service_date = fallback_date
        start_date = fallback_date.strftime("%Y%m%d")
    return trip_id, route_id, service_date, start_date


def parse_feed_messages(
    payloads: list[bytes], now: datetime
) -> dict[tuple[str, str, date], RealtimeTrip]:
    fallback_date = now.astimezone(NYC_TIMEZONE).date()
    records: dict[tuple[str, str, date], RealtimeTrip] = {}
    for source_index, payload in enumerate(payloads):
        message = gtfs_realtime_pb2.FeedMessage()
        message.ParseFromString(payload)
        feed_timestamp = int(message.header.timestamp or 0)
        for entity in message.entity:
            component: Any | None = None
            kind = ""
            if entity.HasField("trip_update"):
                component = entity.trip_update
                kind = "trip_update"
            elif entity.HasField("vehicle"):
                component = entity.vehicle
                kind = "vehicle"
            if component is None:
                continue
            if (
                component.trip.schedule_relationship
                == gtfs_realtime_pb2.TripDescriptor.CANCELED
            ):
                continue
            parsed = _trip_key(component, fallback_date)
            if parsed is None:
                continue
            trip_id, route_id, service_date, start_date = parsed
            key = (trip_id, route_id, service_date)
            record = records.setdefault(
                key,
                RealtimeTrip(
                    trip_id=trip_id,
                    route_id=route_id,
                    service_date=service_date,
                    start_date=start_date,
                    feed_timestamp=feed_timestamp,
                    source_index=source_index,
                ),
            )
            record.feed_timestamp = max(record.feed_timestamp, feed_timestamp)
            if kind == "trip_update":
                record.trip_update = component
            else:
                record.vehicle = component
    return records


def _event_time(event: Any) -> int | None:
    if event is None:
        return None
    value = int(event.time or 0)
    return value if value > 0 else None


def _update_times(
    trip_update: Any | None, context: TripContext | None = None
) -> dict[int, tuple[str, int | None, int | None]]:
    if trip_update is None:
        return {}
    result: dict[int, tuple[str, int | None, int | None]] = {}
    for update in trip_update.stop_time_update:
        sequence = int(update.stop_sequence or 0)
        if sequence <= 0 and context is not None and update.stop_id:
            sequence = next(
                (
                    stop.sequence
                    for stop in context.stops
                    if stop.stop_id == update.stop_id
                ),
                0,
            )
        if sequence <= 0:
            continue
        arrival = _event_time(update.arrival) if update.HasField("arrival") else None
        departure = (
            _event_time(update.departure) if update.HasField("departure") else None
        )
        result[sequence] = (update.stop_id, arrival, departure)
    return result


def _stop_index(stops: tuple[StopOnTrip, ...], sequence: int) -> int | None:
    for index, stop in enumerate(stops):
        if stop.sequence == sequence:
            return index
    return None


def _vehicle_stop_index(
    stops: tuple[StopOnTrip, ...], vehicle: Any | None
) -> int | None:
    if vehicle is None:
        return None
    if vehicle.stop_id:
        for index, stop in enumerate(stops):
            if stop.stop_id == vehicle.stop_id:
                return index
    sequence = int(vehicle.current_stop_sequence or 0)
    return _stop_index(stops, sequence) if sequence > 0 else None


def _scheduled_segment_seconds(previous: StopOnTrip, following: StopOnTrip) -> int:
    previous_time = previous.departure_seconds or previous.arrival_seconds
    following_time = following.arrival_seconds or following.departure_seconds
    if previous_time is None or following_time is None:
        return 90
    return max(following_time - previous_time, 30)


def _realtime_stops_match_static_route(
    trip_update: Any | None,
    vehicle: Any | None,
    context: TripContext,
) -> bool:
    """Reject active reroutes that cannot be represented by this static shape."""
    expected = {stop.sequence: stop.stop_id for stop in context.stops}
    if trip_update is not None:
        for update in trip_update.stop_time_update:
            sequence = int(update.stop_sequence or 0)
            if sequence > 0 and update.stop_id:
                if expected.get(sequence) != update.stop_id:
                    return False
    if vehicle is not None and vehicle.stop_id:
        # NYCT vehicle sequence values do not always line up with supplemented
        # static trip sequences. The explicit GTFS stop_id is the stable key.
        if vehicle.stop_id not in expected.values():
            return False
    return True


def estimate_train(
    realtime: RealtimeTrip,
    context: TripContext,
    now: datetime,
    settings: Settings,
) -> NearbyTrain | None:
    if not _realtime_stops_match_static_route(
        realtime.trip_update, realtime.vehicle, context
    ):
        return None
    now_epoch = int(now.timestamp())
    updates = _update_times(realtime.trip_update, context)
    if not updates:
        return None

    vehicle_sequence = 0
    vehicle_status = gtfs_realtime_pb2.VehiclePosition.IN_TRANSIT_TO
    vehicle_timestamp = 0
    if realtime.vehicle is not None:
        vehicle_sequence = int(realtime.vehicle.current_stop_sequence or 0)
        vehicle_status = int(realtime.vehicle.current_status)
        vehicle_timestamp = int(realtime.vehicle.timestamp or 0)
    observed_epoch = max(realtime.feed_timestamp, vehicle_timestamp)
    if observed_epoch <= 0 or now_epoch - observed_epoch > settings.realtime_stale_seconds:
        return None

    next_index: int | None = None
    if vehicle_sequence > 0 or (
        realtime.vehicle is not None and realtime.vehicle.stop_id
    ):
        index = _vehicle_stop_index(context.stops, realtime.vehicle)
        if index is not None:
            next_index = index + 1 if vehicle_status == gtfs_realtime_pb2.VehiclePosition.STOPPED_AT else index
    if next_index is None or next_index >= len(context.stops):
        for index, stop in enumerate(context.stops):
            update = updates.get(stop.sequence)
            if update and (update[1] or update[2] or 0) >= now_epoch - 30:
                next_index = index
                break
    if next_index is None or next_index <= 0 or next_index >= len(context.stops):
        return None

    next_stop = context.stops[next_index]
    next_update = updates.get(next_stop.sequence)
    next_arrival = (next_update[1] or next_update[2]) if next_update else None
    if next_arrival is None or next_arrival < now_epoch - 5:
        replacement = next(
            (
                (index, update, update[1] or update[2])
                for index in range(next_index + 1, len(context.stops))
                if (update := updates.get(context.stops[index].sequence))
                and (update[1] or update[2]) is not None
                and (update[1] or update[2]) >= now_epoch - 5
            ),
            None,
        )
        if replacement is None:
            return None
        next_index, next_update, next_arrival = replacement
        next_stop = context.stops[next_index]
        vehicle_status = gtfs_realtime_pb2.VehiclePosition.IN_TRANSIT_TO
    previous_stop = context.stops[next_index - 1]

    quality = EstimateQuality.MEDIUM
    if vehicle_status == gtfs_realtime_pb2.VehiclePosition.STOPPED_AT:
        current_index = max(0, next_index - 1)
        current_distance = context.stops[current_index].shape_distance_m
        speed = 0.0
        quality = EstimateQuality.HIGH
        # Stop coordinates represent a station reference point, not the exact
        # location of a 100+ metre consist along the platform.
        horizontal_uncertainty = 90.0
        position_method = "mta_stop_anchor"
        transit_status = "at_station"
        degradation_reason = "platform_position_unavailable"
    else:
        previous_update = updates.get(previous_stop.sequence)
        previous_departure = previous_update[2] if previous_update else None
        if previous_departure is None or previous_departure >= next_arrival:
            previous_departure = next_arrival - _scheduled_segment_seconds(
                previous_stop, next_stop
            )
            quality = EstimateQuality.LOW
        else:
            # Even with realtime times, MTA supplies no vehicle latitude or
            # longitude here. A moving train remains an interpolation.
            quality = EstimateQuality.MEDIUM
        duration = max(next_arrival - previous_departure, 1)
        fraction = min(max((now_epoch - previous_departure) / duration, 0.0), 1.0)
        segment_distance = max(
            next_stop.shape_distance_m - previous_stop.shape_distance_m, 0.0
        )
        current_distance = previous_stop.shape_distance_m + segment_distance * fraction
        speed = min(segment_distance / duration, 25.0)
        uncertainty_fraction = 0.5 if quality == EstimateQuality.LOW else 0.35
        horizontal_uncertainty = max(
            60.0, min(300.0, segment_distance * uncertainty_fraction)
        )
        position_method = "mta_timing_interpolation"
        transit_status = "between_stations"
        degradation_reason = (
            "scheduled_segment_timing"
            if quality == EstimateQuality.LOW
            else "realtime_timing_without_gps"
        )

    lower_chainage = max(0.0, current_distance - horizontal_uncertainty)
    upper_chainage = min(
        context.shape[-1].distance_m,
        current_distance + horizontal_uncertainty,
    )
    position_range = simplify_path(
        context.shape, lower_chainage, upper_chainage, max_points=24
    )

    latitude, longitude, bearing = interpolate_shape(
        context.shape, current_distance
    )
    next_stop_latitude, next_stop_longitude, _ = interpolate_shape(
        context.shape, next_stop.shape_distance_m
    )
    # The client animates this estimate specifically to its next stop. Keep
    # the serialized polyline on that same segment and end it at the exact
    # shape-projected station point; a multi-stop path made the target and
    # rendered rails describe different geometry.
    route_end = next_stop.shape_distance_m
    route_points = simplify_path(context.shape, current_distance, route_end)
    observed_at = datetime.fromtimestamp(observed_epoch, tz=UTC)
    eta_seconds = max(0, next_arrival - now_epoch)
    direction = f"Toward {context.headsign}" if context.headsign else (
        "Direction 1" if context.direction_id == 1 else "Direction 0"
    )
    return NearbyTrain(
        id=f"{realtime.start_date}:{realtime.trip_id}",
        line=context.route_name or context.route_id,
        routeColor=f"#{context.route_color}",
        textColor=f"#{context.text_color}",
        direction=direction,
        previousStation=previous_stop.name,
        nextStation=next_stop.name,
        nextStopPosition=GeoPoint(
            latitude=next_stop_latitude,
            longitude=next_stop_longitude,
        ),
        etaSeconds=eta_seconds,
        etaTime=datetime.fromtimestamp(next_arrival, tz=UTC),
        position=GeoPoint(latitude=latitude, longitude=longitude),
        bearingDegrees=bearing,
        speedMetersPerSecond=max(speed, 0.0),
        distanceFromUserMeters=0,
        approximateDepthMeters=settings.approximate_depth_m,
        # MTA does not publish tunnel altitude. Lower Manhattan is close to
        # mean sea level, so this is explicitly a coarse vertical estimate.
        estimatedAltitudeMeters=-settings.approximate_depth_m,
        horizontalUncertaintyMeters=horizontal_uncertainty,
        verticalUncertaintyMeters=20.0,
        observedAt=observed_at,
        validUntil=observed_at
        + timedelta(seconds=max(settings.poll_interval_seconds * 3, 45)),
        estimateQuality=quality,
        positionMethod=position_method,
        transitStatus=transit_status,
        routeShapeId=context.shape_id,
        segmentId=f"{previous_stop.stop_id}:{next_stop.stop_id}",
        meanChainageMeters=current_distance,
        lowerChainageMeters=lower_chainage,
        upperChainageMeters=upper_chainage,
        nextStopChainageMeters=next_stop.shape_distance_m,
        positionRange=[
            GeoPoint(latitude=point[0], longitude=point[1])
            for point in position_range
        ],
        shapeValidity="matched",
        degradationReason=degradation_reason,
        upcomingRoute=[
            GeoPoint(latitude=point[0], longitude=point[1])
            for point in route_points
        ],
    )


class RealtimeClient:
    def __init__(self, settings: Settings, static_store: StaticGTFSStore) -> None:
        self.settings = settings
        self.static_store = static_store

    async def fetch_snapshot(self) -> RealtimeSnapshot:
        now = datetime.now(tz=UTC)
        async with httpx.AsyncClient(timeout=12, follow_redirects=True) as client:
            results = await asyncio.gather(
                *(client.get(url) for url in self.settings.realtime_feed_urls),
                return_exceptions=True,
            )
        payloads: list[bytes] = []
        errors: list[str] = []
        for url, result in zip(self.settings.realtime_feed_urls, results, strict=True):
            if isinstance(result, Exception):
                errors.append(f"{url}: {result}")
                continue
            try:
                result.raise_for_status()
                payloads.append(result.content)
            except Exception as error:
                errors.append(f"{url}: {error}")
        if not payloads:
            raise RuntimeError("all MTA realtime feeds failed")

        records = parse_feed_messages(payloads, now)
        trains: list[NearbyTrain] = []
        for record in records.values():
            context = self.static_store.trip_context(
                record.trip_id, record.route_id, record.service_date
            )
            if context is None:
                continue
            estimate = estimate_train(record, context, now, self.settings)
            if estimate is not None:
                trains.append(estimate)
        return RealtimeSnapshot(
            generated_at=now,
            trains=tuple(trains),
            source_successes=len(payloads),
            source_failures=len(errors),
            errors=tuple(errors),
        )
