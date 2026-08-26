from __future__ import annotations

import asyncio
from datetime import UTC, datetime

from .config import Settings
from .geometry import haversine_m
from .models import HealthResponse, NearbyResponse
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
        status = "starting"
        if self.static.ready and self.snapshot:
            status = "ok" if self.snapshot.trains else "degraded"
        if age is not None and age > self.settings.snapshot_retention_seconds:
            status = "stale"
        return HealthResponse(
            status=status,
            staticReady=self.static.ready,
            activeTrainCount=len(self.snapshot.trains) if self.snapshot else 0,
            lastRealtimeUpdate=self.snapshot.generated_at if self.snapshot else None,
            feedAgeSeconds=age,
            lastError=self.last_error
            or (
                f"{self.snapshot.source_failures} realtime feed(s) unavailable"
                if self.snapshot and self.snapshot.source_failures
                else None
            ),
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
            if original.validUntil <= now:
                continue
            # Keep the geometric estimate tied to one coherent MTA snapshot.
            # The iPhone evaluates motion continuously from the timestamped
            # chainage/ETA model. Advancing geometry here as well caused the
            # same elapsed time to be applied twice and invalidated the
            # route-aligned uncertainty interval.
            train = original.model_copy(
                update={
                    "etaSeconds": max(
                        0, int((original.etaTime - now).total_seconds())
                    )
                }
            )
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
