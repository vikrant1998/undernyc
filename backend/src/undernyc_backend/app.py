from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware

from .config import Settings
from .models import HealthResponse, NearbyResponse
from .service import TransitService


def create_app(
    settings: Settings | None = None, service: TransitService | None = None
) -> FastAPI:
    configured = settings or Settings.from_env()
    transit_service = service or TransitService(configured)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        await transit_service.start()
        yield
        await transit_service.stop()

    app = FastAPI(
        title="UnderNYC",
        version="0.1.0",
        description="Nearby live MTA subway positions for the UnderNYC AR demo",
        lifespan=lifespan,
    )
    app.state.transit_service = transit_service
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(configured.cors_origins),
        allow_methods=["GET"],
        allow_headers=["*"],
    )

    @app.get("/health", response_model=HealthResponse)
    async def health(request: Request) -> HealthResponse:
        return request.app.state.transit_service.health()

    @app.get("/nearby", response_model=NearbyResponse)
    async def nearby(
        request: Request,
        lat: float = Query(ge=-90, le=90),
        lon: float = Query(ge=-180, le=180),
        radius_m: float = Query(default=configured.default_radius_m, ge=250),
        limit: int = Query(default=configured.default_limit, ge=1),
    ) -> NearbyResponse:
        radius = min(radius_m, configured.maximum_radius_m)
        result_limit = min(limit, configured.maximum_limit)
        try:
            return request.app.state.transit_service.nearby(
                lat, lon, radius, result_limit
            )
        except RuntimeError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error

    return app


app = create_app()

