from datetime import date

from undernyc_backend.static_gtfs import StaticGTFSStore, parse_gtfs_time


def test_gtfs_time_supports_service_after_midnight() -> None:
    assert parse_gtfs_time("25:02:03") == 25 * 3600 + 123


def test_matches_realtime_suffix_and_projects_stops(
    static_store: StaticGTFSStore,
) -> None:
    context = static_store.trip_context(
        "061500_A..N", "A", date(2026, 8, 22)
    )
    assert context is not None
    assert context.route_name == "A"
    assert context.headsign == "Inwood–207 St"
    assert [stop.name for stop in context.stops] == ["First", "Second", "Third"]
    distances = [stop.shape_distance_m for stop in context.stops]
    assert distances == sorted(distances)
    assert distances[-1] > 2000

