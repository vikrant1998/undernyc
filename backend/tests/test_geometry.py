from undernyc_backend.geometry import (
    ShapePoint,
    haversine_m,
    interpolate_shape,
    project_stops_monotonically,
)


def test_haversine_and_interpolation() -> None:
    distance = haversine_m(40.7, -74.0, 40.71, -74.0)
    assert 1100 < distance < 1120
    points = (
        ShapePoint(40.7, -74.0, 0),
        ShapePoint(40.71, -74.0, distance),
    )
    latitude, longitude, bearing = interpolate_shape(points, distance / 2)
    assert latitude == 40.705
    assert longitude == -74.0
    assert bearing < 1 or bearing > 359


def test_stop_projection_never_moves_backward() -> None:
    points = tuple(
        ShapePoint(40.7 + index * 0.001, -74.0, index * 100)
        for index in range(5)
    )
    distances = project_stops_monotonically(
        points,
        [(40.701, -74.0), (40.703, -74.0), (40.7025, -74.0)],
    )
    assert distances == sorted(distances)

