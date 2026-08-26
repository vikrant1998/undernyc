from datetime import UTC, datetime

from fastapi.testclient import TestClient

from undernyc_backend.app import create_app
from undernyc_backend.config import Settings
from undernyc_backend.models import HealthResponse, NearbyResponse


class FakeService:
    def __init__(self, status: str = "ok") -> None:
        self.request: tuple[float, float, float, int] | None = None
        self.status = status

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None

    def health(self) -> HealthResponse:
        return HealthResponse(
            status=self.status,
            staticReady=self.status != "starting",
            activeTrainCount=1,
            lastRealtimeUpdate=datetime.now(tz=UTC),
            feedAgeSeconds=1,
            lastError=None,
        )

    def nearby(
        self, latitude: float, longitude: float, radius_m: float, limit: int
    ) -> NearbyResponse:
        self.request = (latitude, longitude, radius_m, limit)
        return NearbyResponse(
            generatedAt=datetime.now(tz=UTC),
            feedAgeSeconds=1,
            searchRadiusMeters=radius_m,
            trains=[],
        )


def test_api_clamps_demo_radius_and_limit(tmp_path) -> None:
    settings = Settings(data_dir=tmp_path)
    service = FakeService()
    app = create_app(settings, service)  # type: ignore[arg-type]
    with TestClient(app) as client:
        response = client.get(
            "/nearby?lat=40.758&lon=-73.9855&radius_m=9999&limit=99"
        )
    assert response.status_code == 200
    assert service.request == (40.758, -73.9855, 5000, 20)


def test_readiness_fails_until_train_snapshot_is_usable(tmp_path) -> None:
    app = create_app(Settings(data_dir=tmp_path), FakeService(status="starting"))  # type: ignore[arg-type]
    with TestClient(app) as client:
        assert client.get("/health").status_code == 200
        response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["status"] == "starting"


def test_readiness_accepts_usable_snapshot(tmp_path) -> None:
    app = create_app(Settings(data_dir=tmp_path), FakeService())  # type: ignore[arg-type]
    with TestClient(app) as client:
        response = client.get("/ready")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
