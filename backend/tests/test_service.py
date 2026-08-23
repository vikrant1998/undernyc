import asyncio
from datetime import UTC, datetime

from undernyc_backend.config import Settings
from undernyc_backend.models import EstimateQuality, GeoPoint, NearbyTrain
from undernyc_backend.realtime import RealtimeSnapshot
from undernyc_backend.service import TransitService


def _train(identifier: str, latitude: float) -> NearbyTrain:
    now = datetime.now(tz=UTC)
    return NearbyTrain(
        id=identifier,
        line="A",
        routeColor="#0039A6",
        textColor="#FFFFFF",
        direction="Toward Inwood–207 St",
        previousStation="First",
        nextStation="Second",
        etaSeconds=60,
        etaTime=now,
        position=GeoPoint(latitude=latitude, longitude=-74),
        bearingDegrees=0,
        speedMetersPerSecond=10,
        distanceFromUserMeters=0,
        approximateDepthMeters=15,
        observedAt=now,
        validUntil=now,
        estimateQuality=EstimateQuality.HIGH,
        upcomingRoute=[],
    )


def test_nearby_filters_and_sorts(tmp_path) -> None:
    settings = Settings(data_dir=tmp_path)
    service = TransitService(settings)
    now = datetime.now(tz=UTC)
    service.snapshot = RealtimeSnapshot(
        generated_at=now,
        trains=(_train("far", 40.72), _train("near", 40.701)),
        source_successes=8,
        source_failures=0,
    )
    response = service.nearby(40.7, -74, 1000, 15)
    assert [train.id for train in response.trains] == ["near"]


def test_start_does_not_wait_for_static_gtfs_build(tmp_path) -> None:
    async def exercise() -> None:
        settings = Settings(data_dir=tmp_path)
        service = TransitService(settings)
        build_started = asyncio.Event()
        release_build = asyncio.Event()

        def slow_build() -> None:
            build_started_loop.call_soon_threadsafe(build_started.set)
            asyncio.run_coroutine_threadsafe(
                release_build.wait(), build_started_loop
            ).result(timeout=1)

        service.static.ensure_ready = slow_build  # type: ignore[method-assign]
        await asyncio.wait_for(service.start(), timeout=0.1)
        await asyncio.wait_for(build_started.wait(), timeout=0.5)
        assert service.health().status == "starting"
        release_build.set()
        await service.stop()

    build_started_loop = asyncio.new_event_loop()
    try:
        build_started_loop.run_until_complete(exercise())
    finally:
        build_started_loop.close()
