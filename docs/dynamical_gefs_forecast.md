# NOAA GEFS Forecast (35-day) - dynamical.org Reference

> Source: https://dynamical.org/catalog/noaa-gefs-forecast-35-day/

## Overview

The Global Ensemble Forecast System (GEFS) is a NOAA weather model producing 31 separate forecasts (ensemble members) to describe the range of forecast uncertainty. This archive contains past and present GEFS forecasts.

| Property | Value |
|----------|-------|
| Spatial domain | Global |
| Spatial resolution | 0.25° (~20km) for hours 0-240; 0.5° (~40km) for hours 243-840 |
| Initialization | Daily at 00:00 UTC only |
| Forecast length | 0-840 hours (35 days) |
| Temporal steps | 3-hourly (0-240 hrs); 6-hourly (243-840 hrs) |
| Ensemble members | 31 (indexed 0-30) |
| Time domain | 2020-10-01 to Present |

**Endpoint:**
```
https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=YOUR_EMAIL
```

---

## Quick Start

```python
import xarray as xr  # xarray>=2025.1.2 and zarr>=3.0.8 for zarr v3 support

ds = xr.open_zarr("https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=optional@email.com")
ds["temperature_2m"].sel(init_time="2025-01-01T00", latitude=0, longitude=0).max().compute()
```

---

## Dimensions

| Dimension | Min | Max | Units | Notes |
|-----------|-----|-----|-------|-------|
| `ensemble_member` | 0 | 30 | realization | 31 ensemble members |
| `init_time` | 2020-10-01T00 | Present | seconds since 1970-01-01 | Forecast initialization time |
| `lead_time` | 0 | 35 days | seconds | Forecast horizon |
| `latitude` | -90 | 90 | degrees_north | |
| `longitude` | -180 | 179.75 | degrees_east | |

### Lead Time Structure

| Lead Time Range | Temporal Resolution | Spatial Resolution |
|-----------------|--------------------|--------------------|
| 0-240 hours (0-10 days) | 3-hourly | 0.25° (~20km) |
| 243-840 hours (10-35 days) | 6-hourly | 0.5° (~40km) |

---

## Variables

### Temperature & Humidity

| Variable | Description | Units |
|----------|-------------|-------|
| `temperature_2m` | 2 metre temperature | °C |
| `maximum_temperature_2m` | Maximum temperature | °C |
| `minimum_temperature_2m` | Minimum temperature | °C |
| `relative_humidity_2m` | 2 metre relative humidity | % |

### Pressure

| Variable | Description | Units |
|----------|-------------|-------|
| `pressure_surface` | Surface pressure | Pa |
| `pressure_reduced_to_mean_sea_level` | Pressure reduced to MSL | Pa |

### Precipitation

| Variable | Description | Units |
|----------|-------------|-------|
| `precipitation_surface` | Total precipitation (avg rate since previous step) | mm/s |
| `precipitable_water_atmosphere` | Precipitable water | kg/m² |
| `percent_frozen_precipitation_surface` | Percent frozen precipitation | % |

### Precipitation Type (Categorical: 0=no, 1=yes)

| Variable | Description |
|----------|-------------|
| `categorical_rain_surface` | Categorical rain |
| `categorical_snow_surface` | Categorical snow |
| `categorical_freezing_rain_surface` | Categorical freezing rain |
| `categorical_ice_pellets_surface` | Categorical ice pellets |

### Wind

| Variable | Description | Units |
|----------|-------------|-------|
| `wind_u_10m` | 10 metre U wind component | m/s |
| `wind_v_10m` | 10 metre V wind component | m/s |
| `wind_u_100m` | 100 metre U wind component | m/s |
| `wind_v_100m` | 100 metre V wind component | m/s |

### Radiation

| Variable | Description | Units |
|----------|-------------|-------|
| `downward_short_wave_radiation_flux_surface` | Surface downward short-wave radiation flux | W/m² |
| `downward_long_wave_radiation_flux_surface` | Surface downward long-wave radiation flux | W/m² |

### Cloud Cover

| Variable | Description | Units |
|----------|-------------|-------|
| `total_cloud_cover_atmosphere` | Total cloud cover | % |
| `geopotential_height_cloud_ceiling` | Geopotential height | gpm |

---

## Data Processing

### Interpolation

- Bilinear interpolation converts 0.5° data (hours 243-840) to 0.25° grid for consistency
- Original uninterpolated values can be retrieved via `array[::2, ::2]`

### Compression

Data values have been rounded in binary floating-point representation to improve compression ([Klöwer et al. 2021](https://www.nature.com/articles/s43588-021-00156-2)).

---

## Key Differences from Analysis Dataset

| Aspect | Analysis | Forecast (35-day) |
|--------|----------|-------------------|
| Dimensions | `time`, `lat`, `lon` | `init_time`, `lead_time`, `ensemble_member`, `lat`, `lon` |
| Ensemble | None (single realization) | 31 members (0-30) |
| Time coverage | 2000-01-01 to present | 2020-10-01 to present |
| Purpose | Historical "best estimate" | Probabilistic forecasts |

---

## Related Datasets

- **NOAA GEFS Analysis**: Historical weather analysis (no ensemble)
  - Endpoint: `https://data.dynamical.org/noaa/gefs/analysis/latest.zarr`
  - See: [dynamical_gefs_analysis.md](dynamical_gefs_analysis.md)

---

## Technical Notes

- **Storage**: Provided by Source Cooperative (Radiant Earth initiative)
- **Initialization**: Only 00:00 UTC forecasts are archived (not 06, 12, 18 UTC)

---

## Contact

Questions or feature requests: feedback@dynamical.org
