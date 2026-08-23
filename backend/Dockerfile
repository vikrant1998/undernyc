FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UNDERNYC_DATA_DIR=/var/lib/undernyc

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir .
RUN mkdir -p /var/lib/undernyc

EXPOSE 7860
CMD ["sh", "-c", "uvicorn undernyc_backend.app:app --host 0.0.0.0 --port ${PORT:-7860}"]
