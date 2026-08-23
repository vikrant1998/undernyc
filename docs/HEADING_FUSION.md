# Landmark-free heading fusion

UnderNYC runs ARKit with gravity-only world alignment. Absolute north belongs to
`HeadingEstimator`; no landmark, compass arrow, or renderer may maintain a
second yaw correction.

At startup the user rotates the phone for five seconds. The estimator pairs
ARKit camera yaw with timestamp-compatible Core Location headings, rejects poor
Core Motion magnetic samples, and estimates the AR-world-to-true-north offset
with circular statistics. GPS course may subsequently update that offset only
while the device is moving with a sufficiently accurate course.

The estimator exposes a yaw covariance. Precise train geometry is enabled only
at or below an 8-degree standard deviation. Above that threshold the scene root
is disabled and the UI reports uncertainty; it never substitutes a precise
marker. ARKit continues to supply relative orientation while absolute heading
updates are unavailable.

Core Location altitude seeds the vertical position and CMAltimeter stabilizes
relative changes. Backend tunnel altitude and uncertainty remain approximate.
City-scale rendering scales the complete 3D ray uniformly so bearing and
elevation angle are preserved.
