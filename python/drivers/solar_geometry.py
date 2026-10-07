"""
Solar geometry calculations for shortwave radiation correction.

Ported from R/eco4cast-helpers/to_hourly.R (downscale_solar_geom,
cos_solar_zenith_angle, equation_of_time functions).
"""

import numpy as np


def equation_of_time(doy: np.ndarray) -> np.ndarray:
    """
    Equation of time accounting for eccentricity and obliquity.

    Parameters
    ----------
    doy : array-like
        Day of year (can be fractional).

    Returns
    -------
    et : ndarray
        Equation of time in hours.
    """
    f = np.pi / 180 * (279.5 + 0.9856 * doy)
    et = (-104.7 * np.sin(f)
          + 596.2 * np.sin(2 * f)
          + 4.3 * np.sin(4 * f)
          - 429.3 * np.cos(f)
          - 2.0 * np.cos(2 * f)
          + 19.3 * np.cos(3 * f)) / 3600
    return et


def cos_solar_zenith_angle(doy: np.ndarray, lat: np.ndarray,
                           lon: np.ndarray, dt: float,
                           hr: np.ndarray) -> np.ndarray:
    """
    Cosine of the solar zenith angle.

    Parameters
    ----------
    doy : array-like
        Day of year (fractional).
    lat : array-like
        Latitude in degrees.
    lon : array-like
        Longitude in degrees (0-360 convention).
    dt : float
        Time step in seconds.
    hr : array-like
        Hour of day (0-24).

    Returns
    -------
    cosz : ndarray
        Cosine of solar zenith angle, clipped to >= 0.
    """
    et = equation_of_time(doy)
    merid = np.floor(lon / 15) * 15
    merid = np.where(merid < 0, merid + 15, merid)
    lc = (lon - merid) * -4 / 60        # longitude correction (hours)
    tz = merid / 360 * 24               # time zone (hours)
    midbin = 0.5 * dt / 86400 * 24      # shift to bin midpoint (hours)
    t0 = 12 + lc - et - tz - midbin     # solar time
    h = np.pi / 12 * (hr - t0)          # solar hour angle (radians)
    dec = -23.45 * np.pi / 180 * np.cos(2 * np.pi * (doy + 10) / 365)  # declination
    cosz = (np.sin(lat * np.pi / 180) * np.sin(dec)
            + np.cos(lat * np.pi / 180) * np.cos(dec) * np.cos(h))
    cosz = np.maximum(cosz, 0.0)
    return cosz


def potential_solar_radiation(doy: np.ndarray, lon: np.ndarray,
                              lat: np.ndarray) -> np.ndarray:
    """
    Calculate potential (top-of-atmosphere) solar radiation.

    Equivalent to R's downscale_solar_geom().

    Parameters
    ----------
    doy : array-like
        Fractional day of year (e.g., day 100.5 = noon on day 100).
    lon : array-like
        Longitude in degrees (0-360 convention).
    lat : array-like
        Latitude in degrees.

    Returns
    -------
    rpot : ndarray
        Potential solar radiation in W/m².
    """
    doy = np.asarray(doy, dtype=float)
    dt = float(np.median(np.diff(doy)) * 86400)  # seconds between observations
    hr = (doy - np.floor(doy)) * 24               # hour of day

    cosz = cos_solar_zenith_angle(doy, lat, lon, dt, hr)
    rpot = 1366.0 * cosz
    return rpot
