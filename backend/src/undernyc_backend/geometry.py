from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

EARTH_RADIUS_M = 6_371_008.8


@dataclass(frozen=True)
class ShapePoint:
    latitude: float
    longitude: float
    distance_m: float


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    a = (
        math.sin(delta_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2
    )
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def bearing_degrees(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_lambda = math.radians(lon2 - lon1)
    y = math.sin(delta_lambda) * math.cos(phi2)
    x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(
        phi2
    ) * math.cos(delta_lambda)
    return math.degrees(math.atan2(y, x)) % 360


def interpolate_shape(
    points: Sequence[ShapePoint], distance_m: float
) -> tuple[float, float, float]:
    if not points:
        raise ValueError("shape must contain at least one point")
    if len(points) == 1 or distance_m <= points[0].distance_m:
        point = points[0]
        return point.latitude, point.longitude, 0.0
    if distance_m >= points[-1].distance_m:
        point = points[-1]
        previous = points[-2]
        return (
            point.latitude,
            point.longitude,
            bearing_degrees(
                previous.latitude,
                previous.longitude,
                point.latitude,
                point.longitude,
            ),
        )

    low = 0
    high = len(points) - 1
    while low + 1 < high:
        middle = (low + high) // 2
        if points[middle].distance_m <= distance_m:
            low = middle
        else:
            high = middle
    start = points[low]
    end = points[high]
    span = max(end.distance_m - start.distance_m, 1e-9)
    fraction = (distance_m - start.distance_m) / span
    latitude = start.latitude + (end.latitude - start.latitude) * fraction
    longitude = start.longitude + (end.longitude - start.longitude) * fraction
    return (
        latitude,
        longitude,
        bearing_degrees(
            start.latitude, start.longitude, end.latitude, end.longitude
        ),
    )


def project_stops_monotonically(
    points: Sequence[ShapePoint], stops: Sequence[tuple[float, float]]
) -> list[float]:
    """Project ordered stops to a shape without allowing backward jumps."""
    if not points:
        raise ValueError("shape must contain points")
    projected: list[float] = []
    minimum_index = 0
    for stop_latitude, stop_longitude in stops:
        best_index = minimum_index
        best_distance = float("inf")
        for index in range(minimum_index, len(points)):
            point = points[index]
            distance = haversine_m(
                stop_latitude,
                stop_longitude,
                point.latitude,
                point.longitude,
            )
            if distance < best_distance:
                best_distance = distance
                best_index = index
            elif index > best_index + 80 and distance > best_distance * 1.25:
                break
        minimum_index = best_index
        projected.append(points[best_index].distance_m)
    return projected


def simplify_path(
    points: Sequence[ShapePoint], start_m: float, end_m: float, max_points: int = 40
) -> list[tuple[float, float]]:
    selected = [
        (point.latitude, point.longitude)
        for point in points
        if start_m <= point.distance_m <= end_m
    ]
    start = interpolate_shape(points, start_m)
    end = interpolate_shape(points, end_m)
    selected.insert(0, (start[0], start[1]))
    selected.append((end[0], end[1]))
    if len(selected) <= max_points:
        return selected
    stride = math.ceil((len(selected) - 2) / (max_points - 2))
    return [selected[0], *selected[1:-1:stride], selected[-1]]

