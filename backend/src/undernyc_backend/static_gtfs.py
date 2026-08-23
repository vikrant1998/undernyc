from __future__ import annotations

import csv
import io
import os
import sqlite3
import tempfile
import time
import zipfile
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from threading import RLock
from zoneinfo import ZoneInfo

import httpx

from .geometry import ShapePoint, haversine_m, project_stops_monotonically

NYC_TIMEZONE = ZoneInfo("America/New_York")


def parse_gtfs_time(value: str) -> int | None:
    if not value:
        return None
    pieces = value.split(":")
    if len(pieces) != 3:
        return None
    try:
        hours, minutes, seconds = (int(piece) for piece in pieces)
    except ValueError:
        return None
    return hours * 3600 + minutes * 60 + seconds


@dataclass(frozen=True)
class StopOnTrip:
    sequence: int
    stop_id: str
    name: str
    latitude: float
    longitude: float
    arrival_seconds: int | None
    departure_seconds: int | None
    shape_distance_m: float


@dataclass(frozen=True)
class TripContext:
    static_trip_id: str
    realtime_trip_id: str
    route_id: str
    route_name: str
    route_color: str
    text_color: str
    headsign: str
    direction_id: int | None
    service_id: str
    shape_id: str
    stops: tuple[StopOnTrip, ...]
    shape: tuple[ShapePoint, ...]


class StaticGTFSStore:
    def __init__(
        self,
        data_dir: Path,
        primary_url: str,
        fallback_url: str,
        refresh_seconds: float = 3600,
    ) -> None:
        self.data_dir = data_dir
        self.archive_path = data_dir / "subway_gtfs.zip"
        self.database_path = data_dir / "subway_gtfs.sqlite3"
        self.primary_url = primary_url
        self.fallback_url = fallback_url
        self.refresh_seconds = refresh_seconds
        self._lock = RLock()
        self._trip_cache: dict[tuple[str, str, date], TripContext | None] = {}

    @property
    def ready(self) -> bool:
        return self.database_path.exists()

    def ensure_ready(self, force_refresh: bool = False) -> None:
        with self._lock:
            self.data_dir.mkdir(parents=True, exist_ok=True)
            archive_stale = (
                not self.archive_path.exists()
                or time.time() - self.archive_path.stat().st_mtime
                >= self.refresh_seconds
            )
            if force_refresh or archive_stale:
                self._download_archive()
            database_stale = (
                not self.database_path.exists()
                or self.database_path.stat().st_mtime
                < self.archive_path.stat().st_mtime
            )
            if database_stale:
                self._build_database()
                self._trip_cache.clear()

    def _download_archive(self) -> None:
        last_error: Exception | None = None
        for url in (self.primary_url, self.fallback_url):
            temporary = self.archive_path.with_suffix(".download")
            try:
                with httpx.stream("GET", url, timeout=90, follow_redirects=True) as response:
                    response.raise_for_status()
                    with temporary.open("wb") as output:
                        for chunk in response.iter_bytes():
                            output.write(chunk)
                with zipfile.ZipFile(temporary) as archive:
                    required = {"routes.txt", "stops.txt", "trips.txt", "stop_times.txt"}
                    if not required.issubset(archive.namelist()):
                        raise ValueError("downloaded GTFS archive is incomplete")
                os.replace(temporary, self.archive_path)
                return
            except Exception as error:
                last_error = error
                temporary.unlink(missing_ok=True)
        if self.archive_path.exists():
            return
        raise RuntimeError("unable to download an MTA static GTFS archive") from last_error

    @staticmethod
    def _reader(archive: zipfile.ZipFile, name: str) -> Iterator[dict[str, str]]:
        with archive.open(name) as raw:
            with io.TextIOWrapper(raw, encoding="utf-8-sig", newline="") as text:
                yield from csv.DictReader(text)

    def _build_database(self) -> None:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix="undernyc-gtfs-", suffix=".sqlite3", dir=self.data_dir
        )
        os.close(descriptor)
        temporary_path = Path(temporary_name)
        connection = sqlite3.connect(temporary_path)
        try:
            connection.executescript(
                """
                PRAGMA journal_mode=OFF;
                PRAGMA synchronous=OFF;
                PRAGMA temp_store=MEMORY;
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE routes (
                    route_id TEXT PRIMARY KEY,
                    short_name TEXT NOT NULL,
                    long_name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    text_color TEXT NOT NULL
                );
                CREATE TABLE stops (
                    stop_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    parent_station TEXT
                );
                CREATE TABLE trips (
                    trip_id TEXT PRIMARY KEY,
                    route_id TEXT NOT NULL,
                    service_id TEXT NOT NULL,
                    headsign TEXT NOT NULL,
                    direction_id INTEGER,
                    shape_id TEXT NOT NULL
                );
                CREATE TABLE stop_times (
                    trip_id TEXT NOT NULL,
                    stop_id TEXT NOT NULL,
                    stop_sequence INTEGER NOT NULL,
                    arrival_seconds INTEGER,
                    departure_seconds INTEGER,
                    PRIMARY KEY (trip_id, stop_sequence)
                );
                CREATE TABLE shapes (
                    shape_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    cumulative_m REAL NOT NULL,
                    PRIMARY KEY (shape_id, sequence)
                );
                CREATE TABLE calendar (
                    service_id TEXT PRIMARY KEY,
                    monday INTEGER, tuesday INTEGER, wednesday INTEGER,
                    thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER,
                    start_date TEXT, end_date TEXT
                );
                CREATE TABLE calendar_dates (
                    service_id TEXT NOT NULL,
                    service_date TEXT NOT NULL,
                    exception_type INTEGER NOT NULL,
                    PRIMARY KEY (service_id, service_date)
                );
                """
            )
            with zipfile.ZipFile(self.archive_path) as archive:
                self._load_small_tables(connection, archive)
                self._load_shapes(connection, archive)
                self._load_stop_times(connection, archive)
            connection.executescript(
                """
                CREATE INDEX trip_route_idx ON trips(route_id);
                CREATE INDEX trip_service_idx ON trips(service_id);
                CREATE INDEX stop_times_trip_idx ON stop_times(trip_id, stop_sequence);
                CREATE INDEX shapes_id_idx ON shapes(shape_id, sequence);
                CREATE INDEX calendar_dates_date_idx ON calendar_dates(service_date);
                """
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('built_at', ?)",
                (datetime.now(tz=NYC_TIMEZONE).isoformat(),),
            )
            connection.commit()
            connection.close()
            os.replace(temporary_path, self.database_path)
        except Exception:
            connection.close()
            temporary_path.unlink(missing_ok=True)
            raise

    def _load_small_tables(
        self, connection: sqlite3.Connection, archive: zipfile.ZipFile
    ) -> None:
        connection.executemany(
            "INSERT INTO routes VALUES (?, ?, ?, ?, ?)",
            (
                (
                    row["route_id"],
                    row.get("route_short_name", "") or row["route_id"],
                    row.get("route_long_name", ""),
                    (row.get("route_color", "") or "808080").upper(),
                    (row.get("route_text_color", "") or "FFFFFF").upper(),
                )
                for row in self._reader(archive, "routes.txt")
            ),
        )
        connection.executemany(
            "INSERT INTO stops VALUES (?, ?, ?, ?, ?)",
            (
                (
                    row["stop_id"],
                    row.get("stop_name", "Unknown stop"),
                    float(row["stop_lat"]),
                    float(row["stop_lon"]),
                    row.get("parent_station") or None,
                )
                for row in self._reader(archive, "stops.txt")
            ),
        )
        connection.executemany(
            "INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?)",
            (
                (
                    row["trip_id"],
                    row["route_id"],
                    row["service_id"],
                    row.get("trip_headsign", ""),
                    int(row["direction_id"])
                    if row.get("direction_id", "").isdigit()
                    else None,
                    row.get("shape_id", ""),
                )
                for row in self._reader(archive, "trips.txt")
            ),
        )
        if "calendar.txt" in archive.namelist():
            connection.executemany(
                "INSERT INTO calendar VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    (
                        row["service_id"],
                        int(row["monday"]),
                        int(row["tuesday"]),
                        int(row["wednesday"]),
                        int(row["thursday"]),
                        int(row["friday"]),
                        int(row["saturday"]),
                        int(row["sunday"]),
                        row["start_date"],
                        row["end_date"],
                    )
                    for row in self._reader(archive, "calendar.txt")
                ),
            )
        if "calendar_dates.txt" in archive.namelist():
            connection.executemany(
                "INSERT INTO calendar_dates VALUES (?, ?, ?)",
                (
                    (
                        row["service_id"],
                        row["date"],
                        int(row["exception_type"]),
                    )
                    for row in self._reader(archive, "calendar_dates.txt")
                ),
            )

    def _load_shapes(
        self, connection: sqlite3.Connection, archive: zipfile.ZipFile
    ) -> None:
        if "shapes.txt" not in archive.namelist():
            return
        batch: list[tuple[str, int, float, float, float]] = []
        current_shape: str | None = None
        previous: tuple[float, float] | None = None
        cumulative = 0.0
        for row in self._reader(archive, "shapes.txt"):
            shape_id = row["shape_id"]
            latitude = float(row["shape_pt_lat"])
            longitude = float(row["shape_pt_lon"])
            if shape_id != current_shape:
                current_shape = shape_id
                previous = None
                cumulative = 0.0
            if previous is not None:
                cumulative += haversine_m(
                    previous[0], previous[1], latitude, longitude
                )
            previous = (latitude, longitude)
            batch.append(
                (
                    shape_id,
                    int(row["shape_pt_sequence"]),
                    latitude,
                    longitude,
                    cumulative,
                )
            )
            if len(batch) >= 20_000:
                connection.executemany("INSERT INTO shapes VALUES (?, ?, ?, ?, ?)", batch)
                batch.clear()
        if batch:
            connection.executemany("INSERT INTO shapes VALUES (?, ?, ?, ?, ?)", batch)

    def _load_stop_times(
        self, connection: sqlite3.Connection, archive: zipfile.ZipFile
    ) -> None:
        batch: list[tuple[str, str, int, int | None, int | None]] = []
        for row in self._reader(archive, "stop_times.txt"):
            batch.append(
                (
                    row["trip_id"],
                    row["stop_id"],
                    int(row["stop_sequence"]),
                    parse_gtfs_time(row.get("arrival_time", "")),
                    parse_gtfs_time(row.get("departure_time", "")),
                )
            )
            if len(batch) >= 50_000:
                connection.executemany(
                    "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)", batch
                )
                batch.clear()
        if batch:
            connection.executemany(
                "INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)", batch
            )

    def active_services(self, service_date: date) -> set[str]:
        day_key = service_date.strftime("%Y%m%d")
        weekday = service_date.strftime("%A").lower()
        if weekday not in {
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday",
            "sunday",
        }:
            raise ValueError("invalid weekday")
        with sqlite3.connect(self.database_path) as connection:
            active = {
                row[0]
                for row in connection.execute(
                    f"SELECT service_id FROM calendar "
                    f"WHERE {weekday}=1 AND start_date<=? AND end_date>=?",
                    (day_key, day_key),
                )
            }
            for service_id, exception_type in connection.execute(
                "SELECT service_id, exception_type FROM calendar_dates WHERE service_date=?",
                (day_key,),
            ):
                if exception_type == 1:
                    active.add(service_id)
                elif exception_type == 2:
                    active.discard(service_id)
        return active

    def trip_context(
        self, realtime_trip_id: str, route_id: str, service_date: date
    ) -> TripContext | None:
        cache_key = (realtime_trip_id, route_id, service_date)
        with self._lock:
            if cache_key in self._trip_cache:
                return self._trip_cache[cache_key]
            context = self._load_trip_context(
                realtime_trip_id, route_id, service_date
            )
            self._trip_cache[cache_key] = context
            return context

    def _load_trip_context(
        self, realtime_trip_id: str, route_id: str, service_date: date
    ) -> TripContext | None:
        active = self.active_services(service_date)
        with sqlite3.connect(self.database_path) as connection:
            connection.row_factory = sqlite3.Row
            rows = list(
                connection.execute(
                    """
                    SELECT t.*, r.short_name, r.color, r.text_color
                    FROM trips t JOIN routes r ON r.route_id=t.route_id
                    WHERE t.route_id=? AND (t.trip_id=? OR t.trip_id LIKE ?)
                    LIMIT 40
                    """,
                    (route_id, realtime_trip_id, f"%_{realtime_trip_id}"),
                )
            )
            if not rows:
                return None
            rows.sort(
                key=lambda row: (
                    row["service_id"] not in active,
                    row["trip_id"] != realtime_trip_id,
                    len(row["trip_id"]),
                )
            )
            trip = rows[0]
            stop_rows = list(
                connection.execute(
                    """
                    SELECT st.stop_sequence, st.stop_id, st.arrival_seconds,
                           st.departure_seconds, s.name, s.latitude, s.longitude
                    FROM stop_times st JOIN stops s ON s.stop_id=st.stop_id
                    WHERE st.trip_id=? ORDER BY st.stop_sequence
                    """,
                    (trip["trip_id"],),
                )
            )
            if len(stop_rows) < 2:
                return None
            shape_rows = list(
                connection.execute(
                    """
                    SELECT latitude, longitude, cumulative_m FROM shapes
                    WHERE shape_id=? ORDER BY sequence
                    """,
                    (trip["shape_id"],),
                )
            )
        shape = tuple(
            ShapePoint(row["latitude"], row["longitude"], row["cumulative_m"])
            for row in shape_rows
        )
        if len(shape) < 2:
            generated: list[ShapePoint] = []
            cumulative = 0.0
            previous: tuple[float, float] | None = None
            for row in stop_rows:
                if previous is not None:
                    cumulative += haversine_m(
                        previous[0],
                        previous[1],
                        row["latitude"],
                        row["longitude"],
                    )
                generated.append(
                    ShapePoint(row["latitude"], row["longitude"], cumulative)
                )
                previous = (row["latitude"], row["longitude"])
            shape = tuple(generated)
        distances = project_stops_monotonically(
            shape, [(row["latitude"], row["longitude"]) for row in stop_rows]
        )
        stops = tuple(
            StopOnTrip(
                sequence=row["stop_sequence"],
                stop_id=row["stop_id"],
                name=row["name"],
                latitude=row["latitude"],
                longitude=row["longitude"],
                arrival_seconds=row["arrival_seconds"],
                departure_seconds=row["departure_seconds"],
                shape_distance_m=distance,
            )
            for row, distance in zip(stop_rows, distances, strict=True)
        )
        return TripContext(
            static_trip_id=trip["trip_id"],
            realtime_trip_id=realtime_trip_id,
            route_id=trip["route_id"],
            route_name=trip["short_name"],
            route_color=trip["color"],
            text_color=trip["text_color"],
            headsign=trip["headsign"],
            direction_id=trip["direction_id"],
            service_id=trip["service_id"],
            shape_id=trip["shape_id"],
            stops=stops,
            shape=shape,
        )
