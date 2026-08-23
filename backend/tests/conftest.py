from __future__ import annotations

import csv
import io
import zipfile
from pathlib import Path

import pytest

from undernyc_backend.static_gtfs import StaticGTFSStore


def _csv(rows: list[dict[str, object]]) -> bytes:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue().encode()


@pytest.fixture
def static_store(tmp_path: Path) -> StaticGTFSStore:
    archive_path = tmp_path / "subway_gtfs.zip"
    files = {
        "routes.txt": _csv(
            [
                {
                    "route_id": "A",
                    "route_short_name": "A",
                    "route_long_name": "Eighth Avenue Express",
                    "route_color": "0039A6",
                    "route_text_color": "FFFFFF",
                }
            ]
        ),
        "stops.txt": _csv(
            [
                {
                    "stop_id": "S1",
                    "stop_name": "First",
                    "stop_lat": 40.7000,
                    "stop_lon": -74.0000,
                    "parent_station": "",
                },
                {
                    "stop_id": "S2",
                    "stop_name": "Second",
                    "stop_lat": 40.7100,
                    "stop_lon": -74.0000,
                    "parent_station": "",
                },
                {
                    "stop_id": "S3",
                    "stop_name": "Third",
                    "stop_lat": 40.7200,
                    "stop_lon": -74.0000,
                    "parent_station": "",
                },
            ]
        ),
        "trips.txt": _csv(
            [
                {
                    "route_id": "A",
                    "service_id": "WKD",
                    "trip_id": "supplement_WKD_061500_A..N",
                    "trip_headsign": "Inwood–207 St",
                    "direction_id": 0,
                    "shape_id": "shape-a",
                }
            ]
        ),
        "stop_times.txt": _csv(
            [
                {
                    "trip_id": "supplement_WKD_061500_A..N",
                    "arrival_time": "25:00:00",
                    "departure_time": "25:00:10",
                    "stop_id": "S1",
                    "stop_sequence": 1,
                },
                {
                    "trip_id": "supplement_WKD_061500_A..N",
                    "arrival_time": "25:02:00",
                    "departure_time": "25:02:10",
                    "stop_id": "S2",
                    "stop_sequence": 2,
                },
                {
                    "trip_id": "supplement_WKD_061500_A..N",
                    "arrival_time": "25:04:00",
                    "departure_time": "25:04:10",
                    "stop_id": "S3",
                    "stop_sequence": 3,
                },
            ]
        ),
        "shapes.txt": _csv(
            [
                {
                    "shape_id": "shape-a",
                    "shape_pt_lat": 40.7000 + index * 0.002,
                    "shape_pt_lon": -74.0000,
                    "shape_pt_sequence": index,
                }
                for index in range(11)
            ]
        ),
        "calendar.txt": _csv(
            [
                {
                    "service_id": "WKD",
                    "monday": 1,
                    "tuesday": 1,
                    "wednesday": 1,
                    "thursday": 1,
                    "friday": 1,
                    "saturday": 0,
                    "sunday": 0,
                    "start_date": "20260101",
                    "end_date": "20261231",
                }
            ]
        ),
        "calendar_dates.txt": _csv(
            [
                {
                    "service_id": "WKD",
                    "date": "20260822",
                    "exception_type": 1,
                }
            ]
        ),
    }
    with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, contents in files.items():
            archive.writestr(name, contents)
    store = StaticGTFSStore(tmp_path, "unused", "unused", refresh_seconds=999999)
    store.ensure_ready()
    return store

