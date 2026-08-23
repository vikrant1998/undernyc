from datetime import UTC, datetime

from fastapi.testclient import TestClient

from undernyc_backend.app import create_app
from undernyc_backend.config import Settings
from undernyc_backend.models import HealthResponse, NearbyResponse


class FakeService:
    def __init__(self) -> None:
        self.request: tuple[float, float, float, int] | None = None

    async def start(self) -> None:
        return None

    async def stop(self) -> None:
        return None

    def health(self) -> HealthResponse:
        return HealthResponse(
            status="ok",
            staticReady=True,
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

