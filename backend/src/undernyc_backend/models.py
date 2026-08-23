from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class EstimateQuality(StrEnum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class GeoPoint(BaseModel):
    model_config = ConfigDict(extra="forbid")

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class NearbyTrain(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    line: str
    routeColor: str
    textColor: str
    direction: str
    previousStation: str | None
    nextStation: str
    nextStopPosition: GeoPoint | None = None
    etaSeconds: int = Field(ge=0)
    etaTime: datetime
    position: GeoPoint
    bearingDegrees: float = Field(ge=0, lt=360)
    speedMetersPerSecond: float = Field(ge=0)
    distanceFromUserMeters: float = Field(ge=0)
    approximateDepthMeters: float = Field(gt=0)
    estimatedAltitudeMeters: float | None = None
    horizontalUncertaintyMeters: float | None = Field(default=None, ge=0)
    verticalUncertaintyMeters: float | None = Field(default=None, ge=0)
    observedAt: datetime
    validUntil: datetime
    estimateQuality: EstimateQuality
    positionMethod: str = "mta_timing_interpolation"
    transitStatus: str = "between_stations"
    routeShapeId: str | None = None
    segmentId: str | None = None
    meanChainageMeters: float | None = Field(default=None, ge=0)
    lowerChainageMeters: float | None = Field(default=None, ge=0)
    upperChainageMeters: float | None = Field(default=None, ge=0)
    nextStopChainageMeters: float | None = Field(default=None, ge=0)
    positionRange: list[GeoPoint] = Field(default_factory=list)
    shapeValidity: str = "matched"
    degradationReason: str | None = None
    upcomingRoute: list[GeoPoint]


class NearbyResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    generatedAt: datetime
    feedAgeSeconds: float = Field(ge=0)
    searchRadiusMeters: float = Field(gt=0)
    snapshotRevision: str | None = None
    trains: list[NearbyTrain]


class HealthResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: str
    staticReady: bool
    activeTrainCount: int = Field(ge=0)
    lastRealtimeUpdate: datetime | None
    feedAgeSeconds: float | None
    lastError: str | None
