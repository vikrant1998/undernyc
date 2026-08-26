import sqlite3
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


def test_realtime_suffix_treats_sql_wildcards_literally(
    static_store: StaticGTFSStore,
) -> None:
    with sqlite3.connect(static_store.database_path) as connection:
        connection.execute(
            "INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?)",
            ("A", "WKD", "supplement_WKD_061500XA..Q", "Wrong", 0, "shape-a"),
        )
        for sequence, stop_id in enumerate(("S1", "S2"), start=1):
            connection.execute(
                "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)",
                (
                    "supplement_WKD_061500XA..Q",
                    stop_id,
                    sequence,
                    90_000 + sequence * 60,
                    90_010 + sequence * 60,
                ),
            )
    assert static_store.trip_context(
        "061500_A..Q", "A", date(2026, 8, 22)
    ) is None
