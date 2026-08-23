from datetime import UTC, date, datetime

from google.transit import gtfs_realtime_pb2

from undernyc_backend.config import Settings
from undernyc_backend.models import EstimateQuality
from undernyc_backend.realtime import estimate_train, parse_feed_messages
from undernyc_backend.static_gtfs import StaticGTFSStore


def _feed(now_epoch: int) -> bytes:
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.header.gtfs_realtime_version = "2.0"
    feed.header.timestamp = now_epoch

    update_entity = feed.entity.add()
    update_entity.id = "trip"
    update = update_entity.trip_update
    update.trip.trip_id = "061500_A..N"
    update.trip.route_id = "A"
    update.trip.start_date = "20260822"
    for sequence, arrival, departure, stop_id in (
        (1, now_epoch - 70, now_epoch - 60, "S1"),
        (2, now_epoch + 60, now_epoch + 70, "S2"),
        (3, now_epoch + 180, now_epoch + 190, "S3"),
    ):
        stop = update.stop_time_update.add()
        stop.stop_sequence = sequence
        stop.stop_id = stop_id
        stop.arrival.time = arrival
        stop.departure.time = departure

    vehicle_entity = feed.entity.add()
    vehicle_entity.id = "vehicle"
    vehicle = vehicle_entity.vehicle
    vehicle.trip.trip_id = "061500_A..N"
    vehicle.trip.route_id = "A"
    vehicle.trip.start_date = "20260822"
    vehicle.current_stop_sequence = 2
    vehicle.current_status = gtfs_realtime_pb2.VehiclePosition.IN_TRANSIT_TO
    vehicle.timestamp = now_epoch
    return feed.SerializeToString()


def test_parse_and_estimate_train(static_store: StaticGTFSStore) -> None:
    now = datetime(2026, 8, 22, 16, 0, tzinfo=UTC)
    records = parse_feed_messages([_feed(int(now.timestamp()))], now)
    assert len(records) == 1
    realtime = next(iter(records.values()))
    context = static_store.trip_context(
        realtime.trip_id, realtime.route_id, date(2026, 8, 22)
    )
    assert context is not None
    train = estimate_train(realtime, context, now, Settings(data_dir=static_store.data_dir))
    assert train is not None
    assert train.previousStation == "First"
    assert train.nextStation == "Second"
    assert train.nextStopPosition is not None
    assert train.etaSeconds == 60
    assert train.estimateQuality == EstimateQuality.MEDIUM
    assert train.estimatedAltitudeMeters == -15
    assert train.horizontalUncertaintyMeters == 300
    assert train.verticalUncertaintyMeters == 20
    assert train.positionMethod == "mta_timing_interpolation"
    assert train.transitStatus == "between_stations"
    assert train.degradationReason == "realtime_timing_without_gps"
    assert train.shapeValidity == "matched"
    assert train.segmentId == "S1:S2"
    assert train.routeShapeId
    assert train.meanChainageMeters is not None
    assert train.lowerChainageMeters is not None
    assert train.upperChainageMeters is not None
    assert train.nextStopChainageMeters is not None
    assert train.lowerChainageMeters <= train.meanChainageMeters
    assert train.meanChainageMeters <= train.upperChainageMeters
    assert train.positionRange
    assert 40.704 < train.position.latitude < 40.706
    assert train.upcomingRoute


def test_rejects_realtime_reroute_that_conflicts_with_static_shape(
    static_store: StaticGTFSStore,
) -> None:
    now = datetime(2026, 8, 22, 16, 0, tzinfo=UTC)
    records = parse_feed_messages([_feed(int(now.timestamp()))], now)
    realtime = next(iter(records.values()))
    realtime.trip_update.stop_time_update[1].stop_id = "REROUTED_STOP"
    context = static_store.trip_context(
        realtime.trip_id, realtime.route_id, date(2026, 8, 22)
    )
    assert context is not None
    assert estimate_train(
        realtime, context, now, Settings(data_dir=static_store.data_dir)
    ) is None


def test_vehicle_stop_id_wins_when_realtime_sequence_uses_different_numbering(
    static_store: StaticGTFSStore,
) -> None:
    now = datetime(2026, 8, 22, 16, 0, tzinfo=UTC)
    records = parse_feed_messages([_feed(int(now.timestamp()))], now)
    realtime = next(iter(records.values()))
    realtime.vehicle.current_stop_sequence = 3
    realtime.vehicle.stop_id = "S2"
    context = static_store.trip_context(
        realtime.trip_id, realtime.route_id, date(2026, 8, 22)
    )
    assert context is not None
    train = estimate_train(
        realtime, context, now, Settings(data_dir=static_store.data_dir)
    )
    assert train is not None
    assert train.previousStation == "First"
    assert train.nextStation == "Second"


def test_stopped_train_uses_station_anchor_with_platform_uncertainty(
    static_store: StaticGTFSStore,
) -> None:
    now = datetime(2026, 8, 22, 16, 0, tzinfo=UTC)
    records = parse_feed_messages([_feed(int(now.timestamp()))], now)
    realtime = next(iter(records.values()))
    realtime.vehicle.current_status = (
        gtfs_realtime_pb2.VehiclePosition.STOPPED_AT
    )
    realtime.vehicle.stop_id = "S2"
    context = static_store.trip_context(
        realtime.trip_id, realtime.route_id, date(2026, 8, 22)
    )
    assert context is not None
    train = estimate_train(
        realtime, context, now, Settings(data_dir=static_store.data_dir)
    )
    assert train is not None
    assert train.positionMethod == "mta_stop_anchor"
    assert train.transitStatus == "at_station"
    assert train.degradationReason == "platform_position_unavailable"
    assert train.horizontalUncertaintyMeters == 90
