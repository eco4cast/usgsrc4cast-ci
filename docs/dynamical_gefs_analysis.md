# NOAA GEFS Analysis - dynamical.org Reference

> Source: https://dynamical.org/catalog/noaa-gefs-analysis/

## Overview

The Global Ensemble Forecast System (GEFS) is a National Oceanic and Atmospheric Administration (NOAA) National Centers for Environmental Prediction (NCEP) weather forecast model. This **analysis dataset** contains the model's best estimate of past weather conditions, created by concatenating the initial forecast hours.

| Property | Value |
|----------|-------|
| Spatial domain | Global |
| Spatial resolution | 0.25 degrees (~20km) |
| Time domain | 2000-01-01 00:00:00 UTC to Present |
| Time resolution | 3.0 hours |

**Endpoint:**
```
https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=YOUR_EMAIL
```

---

## Quick Start

```python
import xarray as xr  # xarray>=2025.1.2 and zarr>=3.0.8 for zarr v3 support

ds = xr.open_zarr("https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=optional@email.com")
ds["temperature_2m"].sel(time="2025-01-01T00", latitude=0, longitude=0).compute()
```

---

## Dimensions

| Dimension | Min | Max | Units |
|-----------|-----|-----|-------|
| `latitude` | -90 | 90 | degrees_north |
| `longitude` | -180 | 179.75 | degrees_east |
| `time` | 2000-01-01T00:00:00 | Present | seconds since 1970-01-01 |

---

## Variables

### Temperature & Humidity

| Variable | Description | Units | Availability |
|----------|-------------|-------|--------------|
| `temperature_2m` | 2 metre temperature | °C | All times |
| `maximum_temperature_2m` | Maximum temperature | °C | All times |
| `minimum_temperature_2m` | Minimum temperature | °C | All times |
| `relative_humidity_2m` | 2 metre relative humidity | % | After 2020-01-01 |

### Pressure

| Variable | Description | Units | Availability |
|----------|-------------|-------|--------------|
| `pressure_surface` | Surface pressure | Pa | All times |
| `pressure_reduced_to_mean_sea_level` | Pressure reduced to MSL | Pa | All times |

### Precipitation

| Variable | Description | Units | Availability |
|----------|-------------|-------|--------------|
| `precipitation_surface` | Total precipitation (avg rate since previous step) | mm/s | All times |
| `precipitable_water_atmosphere` | Precipitable water | kg/m² | All times |
| `percent_frozen_precipitation_surface` | Percent frozen precipitation (-50 when no precip) | % | After 2020-01-01 |

### Precipitation Type (Categorical: 0=no, 1=yes)

| Variable | Description | Availability |
|----------|-------------|--------------|
| `categorical_rain_surface` | Categorical rain | After 2020-01-01 |
| `categorical_snow_surface` | Categorical snow | After 2020-01-01 |
| `categorical_freezing_rain_surface` | Categorical freezing rain | After 2020-01-01 |
| `categorical_ice_pellets_surface` | Categorical ice pellets | After 2020-01-01 |

### Wind

| Variable | Description | Units | Availability |
|----------|-------------|-------|--------------|
| `wind_u_10m` | 10 metre U wind component | m/s | All times |
| `wind_v_10m` | 10 metre V wind component | m/s | All times |
| `wind_u_100m` | 100 metre U wind component | m/s | All times |
| `wind_v_100m` | 100 metre V wind component | m/s | All times |

### Radiation

| Variable | Description | Units | Notes |
|----------|-------------|-------|-------|
| `downward_short_wave_radiation_flux_surface` | Surface downward short-wave radiation flux | W/m² | Avg over last 3h or 6h period |
| `downward_long_wave_radiation_flux_surface` | Surface downward long-wave radiation flux | W/m² | Avg over last 3h or 6h period |

### Cloud Cover

| Variable | Description | Units | Availability |
|----------|-------------|-------|--------------|
| `total_cloud_cover_atmosphere` | Total cloud cover (avg over last 3h or 6h) | % | All times |
| `geopotential_height_cloud_ceiling` | Geopotential height | gpm | After 2020-09-22 |

---

## Data Sources

The dataset is constructed from three distinct GEFS forecast archives:

| Period | Source | Resolution |
|--------|--------|------------|
| 2000-01-01 to 2019-12-31 | GEFS Reforecast | 0.25°, daily |
| 2020-01-01 to 2020-09-23 | GEFS Forecast Archive | 1.0°, 6-hourly |
| 2020-09-23 to Present | GEFS Operational Forecast | 0.25°, 6-hourly |

---

## Construction Method

To create a single time dimension, the first few hours of each forecast are concatenated:

- **2000-2019**: Daily reforecasts use first 21-24 hours of each forecast
- **2020-Present**: 6-hourly forecasts use first 3-6 hours

**Variable types:**
- **Instantaneous variables**: Use shortest lead times (0 and 3 hours)
- **Accumulated variables**: Use additional forecast step (3 and 6 hours) since no hour-zero values exist

---

## Interpolation

| Period | Spatial Resolution | Temporal Resolution | Interpolation Applied |
|--------|-------------------|---------------------|----------------------|
| 2000-01-01 to 2019-12-31 | 0.25° | 3-hourly | None |
| 2020-01-01 to 2020-09-23 | 1.0° → 0.25° | 6h → 3h | Bilinear spatial + linear temporal |
| 2020-09-23 to Present | 0.25° (0.5° for 100m wind) | 3-hourly | Bilinear for 100m wind only |

> To access original uninterpolated data, select latitudes and longitudes evenly divisible by 1, and (for 2020-01-01 to 2020-09-23) time steps whose hour is divisible by 6.

---

## Related Datasets

- **NOAA GEFS Forecast, 35 day**: Weather forecasts with ensemble members
  - Endpoint: `https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr`
  - See: [dynamical_gefs_forecast.md](dynamical_gefs_forecast.md)

---

## Technical Notes

- **Storage**: Provided by Source Cooperative (Radiant Earth initiative)
- **Compression**: Data values rounded in binary floating-point representation for improved compression ([Klöwer et al. 2021](https://www.nature.com/articles/s43588-021-00156-2))

---

## Contact

Questions or feature requests: feedback@dynamical.org
