from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


DEFAULT_REALTIME_FEEDS = (
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-ace",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-bdfm",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-g",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-jz",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-l",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-nqrw",
    "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-si",
)


@dataclass(frozen=True)
class Settings:
    data_dir: Path = Path("data")
    static_gtfs_url: str = (
        "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_supplemented.zip"
    )
    fallback_static_gtfs_url: str = (
        "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip"
    )
    realtime_feed_urls: tuple[str, ...] = field(
        default_factory=lambda: DEFAULT_REALTIME_FEEDS
    )
    poll_interval_seconds: float = 30.0
    static_refresh_seconds: float = 21_600.0
    realtime_stale_seconds: float = 120.0
    snapshot_retention_seconds: float = 90.0
    default_radius_m: float = 2500.0
    maximum_radius_m: float = 5000.0
    default_limit: int = 15
    maximum_limit: int = 20
    approximate_depth_m: float = 15.0
    cors_origins: tuple[str, ...] = ("*",)

    @classmethod
    def from_env(cls) -> "Settings":
        feeds = os.getenv("UNDERNYC_REALTIME_FEEDS")
        origins = os.getenv("UNDERNYC_CORS_ORIGINS", "*")
        return cls(
            data_dir=Path(os.getenv("UNDERNYC_DATA_DIR", "data")),
            static_gtfs_url=os.getenv(
                "UNDERNYC_STATIC_GTFS_URL",
                "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_supplemented.zip",
            ),
            fallback_static_gtfs_url=os.getenv(
                "UNDERNYC_FALLBACK_STATIC_GTFS_URL",
                "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip",
            ),
            realtime_feed_urls=tuple(
                part.strip() for part in feeds.split(",") if part.strip()
            )
            if feeds
            else DEFAULT_REALTIME_FEEDS,
            poll_interval_seconds=float(
                os.getenv("UNDERNYC_POLL_INTERVAL_SECONDS", "30")
            ),
            static_refresh_seconds=float(
                os.getenv("UNDERNYC_STATIC_REFRESH_SECONDS", "21600")
            ),
            realtime_stale_seconds=float(
                os.getenv("UNDERNYC_REALTIME_STALE_SECONDS", "120")
            ),
            snapshot_retention_seconds=float(
                os.getenv("UNDERNYC_SNAPSHOT_RETENTION_SECONDS", "90")
            ),
            approximate_depth_m=float(
                os.getenv("UNDERNYC_APPROXIMATE_DEPTH_M", "15")
            ),
            cors_origins=tuple(
                part.strip() for part in origins.split(",") if part.strip()
            ),
        )
