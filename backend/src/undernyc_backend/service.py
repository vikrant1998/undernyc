from __future__ import annotations

import asyncio
from datetime import UTC, datetime

from .config import Settings
from .geometry import bearing_degrees, haversine_m
from .models import GeoPoint, HealthResponse, NearbyResponse, NearbyTrain
from .realtime import RealtimeClient, RealtimeSnapshot
from .static_gtfs import StaticGTFSStore


class TransitService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.static = StaticGTFSStore(
            settings.data_dir,
            settings.static_gtfs_url,
            settings.fallback_static_gtfs_url,
            settings.static_refresh_seconds,
        )
        self.realtime = RealtimeClient(settings, self.static)
        self.snapshot: RealtimeSnapshot | None = None
        self.last_error: str | None = None
        self._task: asyncio.Task[None] | None = None
        self._stop = asyncio.Event()

    async def start(self) -> None:
        self._stop.clear()
        if self._task is None:
            self._task = asyncio.create_task(
                self._initialize_and_poll(), name="mta-transit-service"
            )

    async def stop(self) -> None:
        self._stop.set()
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    async def _initialize_and_poll(self) -> None:
        # Building the static GTFS index can take several minutes on a cold,
        # small cloud instance. Keep it off the ASGI startup path so the web
        # server can bind immediately and expose an honest `starting` health
        # response while initialization proceeds.
        while not self._stop.is_set() and not self.static.ready:
            try:
                await asyncio.to_thread(self.static.ensure_ready)
                self.last_error = None
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self.last_error = str(error)
                await asyncio.sleep(self.settings.poll_interval_seconds)

        if self._stop.is_set():
            return

        try:
            self.snapshot = await self.realtime.fetch_snapshot()
            self.last_error = None
        except asyncio.CancelledError:
            raise
        except Exception as error:
            self.last_error = str(error)

        next_static_refresh = asyncio.get_running_loop().time() + self.settings.static_refresh_seconds
        while not self._stop.is_set():
            try:
                await asyncio.sleep(self.settings.poll_interval_seconds)
                if asyncio.get_running_loop().time() >= next_static_refresh:
                    await asyncio.to_thread(self.static.ensure_ready)
                    next_static_refresh = (
                        asyncio.get_running_loop().time()
                        + self.settings.static_refresh_seconds
                    )
                self.snapshot = await self.realtime.fetch_snapshot()
                self.last_error = None
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self.last_error = str(error)

    def health(self) -> HealthResponse:
        now = datetime.now(tz=UTC)
        age = (
            max(0.0, (now - self.snapshot.generated_at).total_seconds())
            if self.snapshot
            else None
        )
        status = "ok" if self.static.ready and self.snapshot else "starting"
        if age is not None and age > self.settings.snapshot_retention_seconds:
            status = "stale"
        return HealthResponse(
            status=status,
            staticReady=self.static.ready,
            activeTrainCount=len(self.snapshot.trains) if self.snapshot else 0,
            lastRealtimeUpdate=self.snapshot.generated_at if self.snapshot else None,
            feedAgeSeconds=age,
            lastError=self.last_error,
        )

    def nearby(
        self, latitude: float, longitude: float, radius_m: float, limit: int
    ) -> NearbyResponse:
        if self.snapshot is None:
            raise RuntimeError("realtime train data is not ready")
        now = datetime.now(tz=UTC)
        feed_age = max(0.0, (now - self.snapshot.generated_at).total_seconds())
        if feed_age > self.settings.snapshot_retention_seconds:
            raise RuntimeError("realtime train data is stale")
        nearby = []
        for original in self.snapshot.trains:
            train = self._advance_train(original, min(feed_age, 30.0), now)
            distance = haversine_m(
                latitude,
                longitude,
                train.position.latitude,
                train.position.longitude,
            )
            if distance <= radius_m:
                nearby.append(
                    train.model_copy(update={"distanceFromUserMeters": distance})
                )
        nearby.sort(key=lambda train: train.distanceFromUserMeters)
        return NearbyResponse(
            generatedAt=now,
            feedAgeSeconds=feed_age,
            searchRadiusMeters=radius_m,
            snapshotRevision=self.snapshot.generated_at.isoformat(),
            trains=nearby[:limit],
        )

    @staticmethod
    def _advance_train(
        train: NearbyTrain, elapsed_seconds: float, now: datetime
    ) -> NearbyTrain:
        requested_advance = max(0.0, train.speedMetersPerSecond * elapsed_seconds)
        if (
            train.meanChainageMeters is not None
            and train.nextStopChainageMeters is not None
        ):
            requested_advance = min(
                requested_advance,
                max(0.0, train.nextStopChainageMeters - train.meanChainageMeters),
            )
        remaining = requested_advance
        current = train.position
        remaining_path: list[GeoPoint] = []
        bearing = train.bearingDegrees
        route = [point for point in train.upcomingRoute if point != current]
        for index, following in enumerate(route):
            segment = haversine_m(
                current.latitude,
                current.longitude,
                following.latitude,
                following.longitude,
            )
            if remaining <= segment or segment <= 0:
                if segment <= 0:
                    continue
                fraction = min(remaining / max(segment, 1e-9), 1.0)
                bearing = bearing_degrees(
                    current.latitude,
                    current.longitude,
                    following.latitude,
                    following.longitude,
                )
                current = GeoPoint(
                    latitude=current.latitude
                    + (following.latitude - current.latitude) * fraction,
                    longitude=current.longitude
                    + (following.longitude - current.longitude) * fraction,
                )
                remaining_path = [current, *route[index:]]
                # The requested distance was consumed inside this segment.
                # Leaving `remaining` unchanged moved the coordinate while
                # reporting zero achieved chainage, causing the iPhone to
                # apply the same movement a second time.
                remaining = 0.0
                break
            remaining -= segment
            current = following
        else:
            remaining_path = [current]
        achieved_advance = max(0.0, requested_advance - remaining)
        chainage_updates: dict[str, float] = {}
        if train.meanChainageMeters is not None:
            advanced_mean = train.meanChainageMeters + achieved_advance
            if train.nextStopChainageMeters is not None:
                advanced_mean = min(advanced_mean, train.nextStopChainageMeters)
            chainage_updates["meanChainageMeters"] = advanced_mean
        if train.lowerChainageMeters is not None:
            advanced_lower = train.lowerChainageMeters + achieved_advance
            if "meanChainageMeters" in chainage_updates:
                advanced_lower = min(
                    advanced_lower, chainage_updates["meanChainageMeters"]
                )
            chainage_updates["lowerChainageMeters"] = advanced_lower
        if train.upperChainageMeters is not None:
            advanced_upper = train.upperChainageMeters + achieved_advance
            if train.nextStopChainageMeters is not None:
                advanced_upper = min(advanced_upper, train.nextStopChainageMeters)
            if "meanChainageMeters" in chainage_updates:
                advanced_upper = max(
                    advanced_upper, chainage_updates["meanChainageMeters"]
                )
            chainage_updates["upperChainageMeters"] = advanced_upper
        return train.model_copy(
            update={
                "position": current,
                "bearingDegrees": bearing,
                "etaSeconds": max(0, int((train.etaTime - now).total_seconds())),
                "upcomingRoute": remaining_path,
                # The original range geometry is tied to the source snapshot.
                # Until it is regenerated from the static shape, omitting it
                # is safer than drawing a visibly stale uncertainty band.
                "positionRange": [] if achieved_advance > 0 else train.positionRange,
                **chainage_updates,
            }
        )
