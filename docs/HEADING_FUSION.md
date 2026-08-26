# Landmark-free heading fusion

UnderNYC no longer uses this estimator as Street mode's spatial authority.
Street mode uses Apple's outdoor geotracking plus a tracked `ARGeoAnchor`, which
provides the map-to-AR transform and an east/up/south local frame. Platform mode
uses gravity-only tracking plus the user's one-tap incoming-track axis.

`HeadingEstimator` remains available for diagnostics and experiments. It can
pair ARKit camera yaw with timestamp-compatible Core Location headings, reject
poor Core Motion magnetic samples, and estimate an AR-world-to-true-north offset
with circular statistics. GPS course is never treated as camera direction.

Its covariance is reported in diagnostics but never rotates geographic content
or overrides an `ARGeoAnchor`. This prevents two competing heading corrections
from making routes, markers, and arrows disagree.

Core Location altitude and CMAltimeter remain diagnostic inputs. The live train
layer uses a clearly illustrative depth below the geo anchor's mapped ground;
MTA does not publish tunnel altitude. Street rendering preserves literal
horizontal metres and a fixed symbolic depth; perspective naturally makes a
distant train appear smaller.
