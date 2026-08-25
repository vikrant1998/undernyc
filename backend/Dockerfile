FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UNDERNYC_DATA_DIR=/var/lib/undernyc

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir .
RUN mkdir -p /var/lib/undernyc
# Build the static subway index into the image. Render's runtime filesystem is
# ephemeral, so constructing it only after boot makes every cold start return
# 503 for several minutes. Baking it into an image layer keeps `/nearby`
# available as soon as the container starts; the service still refreshes the
# data in the background while it is running.
RUN python -c "from undernyc_backend.config import Settings; from undernyc_backend.static_gtfs import StaticGTFSStore; s = Settings.from_env(); StaticGTFSStore(s.data_dir, s.static_gtfs_url, s.fallback_static_gtfs_url, s.static_refresh_seconds).ensure_ready()"

EXPOSE 7860
CMD ["sh", "-c", "uvicorn undernyc_backend.app:app --host 0.0.0.0 --port ${PORT:-7860}"]
