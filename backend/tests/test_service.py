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

