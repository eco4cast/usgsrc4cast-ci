This is documentation for things to be aware of when migrating the drivers workflow from downloading GEFS from grib file and processing them in-house, to using dynamical.org dataset (which already processes the GEFS data https://dynamical.org/catalog/models/noaa-gefs/) instead.

## Goals
- Make the drivers pipeline run much more efficiently than processing GEFS ourselves
- Make the datasets compatible with the current structure on s3 buckets so that the forecast challenge can continue smoothly
- Final dataset should be parquet data that matches the dataframes on s3

---

## Current Stage Definitions (gefs4cast)

Understanding the current pipeline is critical for mapping to dynamical.org:

### pseudo (Pseudo-historical forecasts)
- **What it is**: Historical "forecast" data created by treating past GEFS analysis/observations as if they were forecasts
- **Date range**: 2020-09-24 to present
- **Purpose**: Provides continuous historical driver data for model training
- **Processing**: Uses `gefs4cast:::gefs_pseudo_measures()` internal function
- **dynamical.org equivalent**: **GEFS Analysis** dataset (`/noaa/gefs/analysis/`)

### stage1 (Raw GEFS extractions)
- **What it is**: Raw NOAA GEFS v12 forecasts extracted at site coordinates
- **Variants**:
  - `stage1`: Full 31 ensemble members (gep01-gep30 + gec00 control)
  - `stage1-stats`: Summary statistics only (geavg, gespr)
- **Temporal resolution**: 3-hour (days 1-10), 6-hour (days 11-30)
- **dynamical.org equivalent**: Not needed - dynamical already does the extraction

### stage2 (Hourly site forecasts)
- **What it is**: Stage1 data processed to hourly resolution with CF variable names
- **Processing**:
  1. Interpolated from 3/6 hour to 1-hour intervals
  2. Fluxes converted to per-second rates
  3. Variables renamed to CF conventions
- **Partitioning**: `reference_datetime/site_id`
- **dynamical.org equivalent**: **GEFS Forecast 35-day** dataset, post-processed

### stage3 (Pseudo-historical hourly nowcast)
- **What it is**: Hourly resolution pseudo-historical data with solar geometry corrections
- **Purpose**: Used for model initialization and historical driver data
- **Partitioning**: `site_id` only
- **dynamical.org equivalent**: **GEFS Analysis** processed to hourly with solar geometry

---

## Current GEFS Data Schemas (Verified from Parquet Files)

> Source: Actual parquet data accessed via `R/eco4cast-helpers/noaa_gefs.R`

### Stage 1 Schema (Raw GEFS)

**S3 Path:** `bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage1/reference_datetime={date}`

| Column | Type | Example | Description |
|--------|------|---------|-------------|
| `site_id` | string | "USGS-01427510" | Site identifier |
| `datetime` | timestamp | 2025-01-01 12:00:00 | Valid time of forecast |
| `variable` | string | "TMP", "RH", "PRES" | GRIB variable name |
| `prediction` | float | 2.32 (for TMP) | Forecast value |
| `ensemble` | string | "gec00", "gep01"..."gep30" | Ensemble member |
| `horizon` | duration | 43200 secs (12 hrs) | Forecast lead time |
| `cycle` | string | "00" | Forecast cycle (00, 06, 12, 18) |
| `family` | string | "ensemble" | Forecast family/type |

**Stage 1 Variables (GRIB names) - Verified:**
| Variable | Description | Units | Example Value |
|----------|-------------|-------|---------------|
| `TMP` | Temperature | **°C** (not K!) | 2.32 |
| `RH` | Relative humidity | % | 98.5 |
| `PRES` | Atmospheric pressure | Pa | 93388.56 |
| `UGRD` | U-component of wind speed | m/s | 0.933 |
| `VGRD` | V-component of wind speed | m/s | 0.658 |
| `APCP` | Total precipitation in interval | kg/m² | 3.30 |
| `DSWRF` | Downward shortwave radiation flux | W/m² | - |
| `DLWRF` | Downward longwave radiation flux | W/m² | - |
| `TMAX` | Maximum temperature | °C | 2.37 |
| `TMIN` | Minimum temperature | °C | 2.13 |
| `TCDC` | Total cloud cover | % | - |
| `PWAT` | Precipitable water | kg/m² | 12.2 |

> ⚠️ **Note:** The documentation in `noaa_gefs.R` incorrectly states TMP is in Kelvin. It is actually in **Celsius**.

### Stage 2 Schema (Hourly, CF Names)

**S3 Path:** `bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage2/reference_datetime={date}/site_id={site_id}`

| Column | Type | Example | Description |
|--------|------|---------|-------------|
| `site_id` | string | "USGS-05543010" | Site identifier |
| `datetime` | timestamp | 2025-01-19 20:00:00 | Valid time (hourly) |
| `variable` | string | "air_temperature" | CF convention variable name |
| `prediction` | float | 274.99 | Forecast value |
| `parameter` | int | 30 | Ensemble member number (0-30) |
| `reference_datetime` | timestamp | 2025-01-01 | Forecast initialization time |
| `family` | string | "ensemble" | Forecast family/type |

**Stage 2 Variables (CF convention names) - Verified:**
| Variable | Description | Units | Example Value | Transformation |
|----------|-------------|-------|---------------|----------------|
| `air_temperature` | 2m temperature | K | 274.99 | TMP + 273 |
| `air_pressure` | Surface pressure | Pa | 98348.11 | direct |
| `relative_humidity` | 2m relative humidity | fraction | 0.995 | RH / 100 |
| `northward_wind` | U-component wind | m/s | -0.524 | direct |
| `eastward_wind` | V-component wind | m/s | -2.68 | direct |
| `precipitation_flux` | Precipitation rate | kg/m²/s | 2.31e-5 | APCP / (6*3600) |
| `surface_downwelling_shortwave_flux_in_air` | SW radiation | W/m² | 90.7 | solar geometry |
| `surface_downwelling_longwave_flux_in_air` | LW radiation | W/m² | 320.0 | direct |

### Stage 3 Schema (Pseudo-historical Nowcast)

**S3 Path:** `bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage3/site_id={site_id}`

| Column | Type | Example | Description |
|--------|------|---------|-------------|
| `site_id` | string | "USGS-01427510" | Site identifier |
| `datetime` | timestamp | 2025-01-01 01:00:00 | Valid time (hourly) |
| `variable` | string | "air_temperature" | CF convention variable name |
| `prediction` | float | 276.47 | Forecast value |
| `parameter` | int | 0-30 | Ensemble member number |
| `reference_datetime` | NA (logical) | NA | Not applicable for nowcast |
| `family` | string | "ensemble" | Forecast family/type |

Same variables as Stage 2, with:
- `reference_datetime` is **NA** (not a timestamp)
- Continuous time series combining multiple forecast cycles
- All 31 ensemble members (parameter 0-30)
- Hourly temporal resolution

### Access Functions

```r
# Stage 1 - Raw GEFS
noaa_stage1(project_id = 'usgsrc4cast', start_date = '2025-01-01') |> collect()

# Stage 2 - Hourly with CF names
noaa_stage2(project_id = 'usgsrc4cast', start_date = '2025-01-01') |> collect()

# Stage 3 - Pseudo-historical nowcast
noaa_stage3(project_id = 'usgsrc4cast') |>
  filter(datetime > as.Date('2025-01-01')) |> collect()
```

---

## Variable Mapping

### Challenge Variables (Current → dynamical.org)

| Challenge Name | CF Name (stage2/3) | dynamical.org Variable | Units | Transformation Required |
|---------------|---------------------|------------------------|-------|------------------------|
| `TMP` | `air_temperature` | `temperature_2m` | °C | **Convert to K: add 273.15** |
| `PRES` | `air_pressure` | `pressure_surface` | Pa | None (direct mapping) |
| `RH` | `relative_humidity` | `relative_humidity_2m` | % | Divide by 100 (to fraction) |
| `UGRD` | `northward_wind` | `wind_u_10m` | m/s | None (direct mapping) |
| `VGRD` | `eastward_wind` | `wind_v_10m` | m/s | None (direct mapping) |
| `APCP` | `precipitation_flux` | `precipitation_surface` | mm/s | **None - already a rate!** |
| `DSWRF` | `surface_downwelling_shortwave_flux_in_air` | `downward_short_wave_radiation_flux_surface` | W/m² | Apply solar geometry correction |
| `DLWRF` | `surface_downwelling_longwave_flux_in_air` | `downward_long_wave_radiation_flux_surface` | W/m² | None (direct mapping) |

### Key Findings from dynamical.org Documentation

1. **Temperature is in °C, not Kelvin** - Must add 273.15 to convert to K for compatibility
2. **Precipitation is already a rate** (mm/s) - No need to divide by accumulation period
3. **All required variables are available**:
   - `pressure_surface` ✓ (Pa)
   - `relative_humidity_2m` ✓ (%, but only available after 2020-01-01)
4. **Radiation variables are period averages** - Average over last 3h or 6h period

### ✅ Temperature Unit Clarification (Verified)

**Finding from actual parquet data:**
- Stage 1 `TMP` is in **Celsius (°C)**, not Kelvin as documented in `noaa_gefs.R`
- Example: TMP = 2.32°C (clearly not 2.32 K which would be -271°C)
- `to_hourly.R` correctly adds 273 to convert °C → K
- Stage 2/3 `air_temperature` is correctly in Kelvin (e.g., 274.99 K)

**For dynamical.org migration:**
- Dynamical `temperature_2m` is also in **°C**
- Apply same transformation: `temperature_2m + 273.15` → `air_temperature` in K
- Note: Current code uses +273, should ideally be +273.15 for precision

### Variables to Request from dynamical.org
```python
variables = [
    "temperature_2m",                              # TMP → needs +273.15
    "pressure_surface",                            # PRES
    "relative_humidity_2m",                        # RH → divide by 100
    "wind_u_10m",                                  # UGRD
    "wind_v_10m",                                  # VGRD
    "precipitation_surface",                       # APCP → already mm/s
    "downward_short_wave_radiation_flux_surface",  # DSWRF
    "downward_long_wave_radiation_flux_surface",   # DLWRF
]
```

### Variable Availability Notes
- `relative_humidity_2m`: **Unavailable before 2020-01-01** in analysis dataset
- All other variables available from 2000-01-01 (analysis) or 2020-10-01 (forecast)

---

## Dynamical.org API Details

### Access: STAC catalog + Icechunk (current pattern)

> **Updated access pattern (2026):** dynamical.org now serves its datasets through a
> STAC catalog backed by **Icechunk** repositories. This replaces the older
> `.../latest.zarr?email=YOUR_EMAIL` HTTP-zarr URLs (no email query param is needed
> anymore). See `python/dynamical_utils.py::open_dynamical()` and the reference
> implementation in the chronos2 forecast project (`src/fetch_covariates.py`).

```
STAC catalog:  https://stac.dynamical.org/catalog.json
Analysis:      STAC child id  "noaa-gefs-analysis"           (asset "icechunk-https")
Forecast:      STAC child id  "noaa-gefs-forecast-35-day"    (asset "icechunk-https")
```

The datasets are opened by resolving the STAC child, opening its `icechunk-https`
asset as a read-only Icechunk repository, and handing the session store to
`xr.open_zarr`. Behind a TLS-inspecting proxy (e.g. USGS) `truststore.inject_into_ssl()`
routes HTTPS through the OS trust store so the self-signed root CA is accepted.

#### Legacy endpoints (deprecated)
```
Analysis:     https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=YOUR_EMAIL
Forecast:     https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=YOUR_EMAIL
```

### Dataset Specifications

| Property | Analysis | Forecast (35-day) |
|----------|----------|-------------------|
| Spatial resolution | 0.25° (~20km) | 0.25° (days 0-10), 0.5° (days 10-35) |
| Temporal resolution | 3-hourly | 3-hourly (days 0-10), 6-hourly (days 10-35) |
| Time coverage | 2000-01-01 to present | 2020-10-01 to present |
| Ensemble members | None (single realization) | 31 members (indexed 0-30) |
| Initialization | N/A | **00:00 UTC only** |

### Dimensions

**Analysis Dataset:**
| Dimension | Min | Max | Units |
|-----------|-----|-----|-------|
| `time` | 2000-01-01T00 | Present | seconds since 1970-01-01 |
| `latitude` | -90 | 90 | degrees_north |
| `longitude` | -180 | 179.75 | degrees_east |

**Forecast Dataset:**
| Dimension | Min | Max | Units |
|-----------|-----|-----|-------|
| `init_time` | 2020-10-01T00 | Present | seconds since 1970-01-01 |
| `lead_time` | 0 | 840 hours (35 days) | seconds |
| `ensemble_member` | 0 | 30 | realization (31 total) |
| `latitude` | -90 | 90 | degrees_north |
| `longitude` | -180 | 179.75 | degrees_east |

### Lead Time Structure (Forecast)
| Lead Time Range | Temporal Resolution | Spatial Resolution |
|-----------------|--------------------|--------------------|
| 0-240 hours (0-10 days) | 3-hourly | 0.25° |
| 243-840 hours (10-35 days) | 6-hourly | 0.5° (interpolated to 0.25°) |

### Access Pattern (from dynamical_utils.py)
```python
import functools

import icechunk
import pystac
import xarray as xr

try:
    import truststore  # accept the USGS TLS-inspecting proxy's root CA
    truststore.inject_into_ssl()
except ImportError:
    pass

DYNAMICAL_CATALOG = "https://stac.dynamical.org/catalog.json"


@functools.cache
def open_dynamical(dataset_id: str) -> xr.Dataset:
    """Open a dynamical.org dataset via its STAC entry as a read-only Dataset."""
    catalog = pystac.Catalog.from_file(DYNAMICAL_CATALOG)
    asset = catalog.get_child(dataset_id).assets["icechunk-https"]
    repo = icechunk.Repository.open(icechunk.http_storage(asset.href))
    session = repo.readonly_session("main")
    return xr.open_zarr(session.store, chunks=None, decode_timedelta=True)


# Analysis (for pseudo/stage3)
analysis = open_dynamical("noaa-gefs-analysis")

# Forecast (for stage2) — select an init, then swap to the provided valid_time coord
forecast = open_dynamical("noaa-gefs-forecast-35-day")
fc = (
    forecast.sel(init_time=init_time, lead_time=slice("0h", "35d"))
    .swap_dims({"lead_time": "valid_time"})
)
```

### Important Notes
- **Forecast init times**: Only 00:00 UTC forecasts are archived (not 06, 12, 18 UTC)
- **Interpolation**: 0.5° data is bilinearly interpolated to 0.25° for consistency
- **Forecast start date**: 2020-10-01, slightly later than current pseudo (2020-09-24)
- **Staged publication**: The 35-day forecast is published in segments — dynamical.org
  ingests the 0–16 day portion first and backfills days 16–35 hours later. On a run
  day the newest init may only cover ~16 lead days. Consumers that need the full
  horizon should check `lead_time` coverage and, if short, fall back to the most
  recent init that spans the horizon (see `fetch_covariates.py::_candidate_init_times`
  in the chronos2 project; `download_dynamical.py` currently warns on short coverage).
- **`valid_time` coordinate**: The forecast dataset carries a `valid_time` coordinate
  indexed by `lead_time`; use `swap_dims({"lead_time": "valid_time"})` instead of
  recomputing `init_time + lead_time` by hand.

---

## Migration Strategy

### Phase 1: Exploration & Validation
1. **Inspect dynamical zarr stores** to confirm:
   - All required variables are available
   - Ensemble member handling (how many, dimension structure)
   - Temporal coverage matches needs (2020-09-24 onward)
   - Spatial resolution and coordinate system

2. **Download sample data** for one site and compare against current pipeline output

### Phase 2: Build New Pipeline Components ✅ COMPLETED

#### Python Scripts Created:

**`python/drivers/download_dynamical.py`** - Main CLI orchestrator
- Replaces: `download_stage1_pseudo.R`, `generate_stage2.R`, `generate_stage3.R`
- Functions: `generate_stage2()`, `generate_stage3()`
- CLI: `python -m python.drivers.download_dynamical stage2|stage3 [options]`

**`python/drivers/process_to_hourly.py`** - Hourly processing
- Ported from `R/eco4cast-helpers/to_hourly.R`
- Interpolation: linear for state vars (temp, pressure, RH, wind), forward-fill for fluxes (precip, radiation)
- Solar geometry correction for shortwave radiation (redistributes using potential radiation)
- Variable transforms: dynamical.org units → CF convention units
- Key functions: `process_forecast_to_stage2()`, `process_analysis_to_stage3()`

**`python/drivers/solar_geometry.py`** - Solar geometry calculations
- Ported from `to_hourly.R`: `equation_of_time()`, `cos_solar_zenith_angle()`, `potential_solar_radiation()`
- Solar constant: 1366 W/m², uses 0-360 longitude convention
- Tested: produces correct diurnal cycle (peak at local noon, zero at night)

**`python/drivers/write_parquet.py`** - Output formatting
- `write_stage2_parquet()`: partitioned by `reference_datetime={date}/site_id={site}/`
- `write_stage3_parquet()`: partitioned by `site_id={site}/`
- Drops partition columns from data (stored in directory structure)

#### End-to-End Test Results (2025-09-01, 2 sites, 3-day forecast):
- Stage 2: 46,624 rows, 31 ensemble members, 8 CF variables, hourly resolution
- Temperature in Kelvin (286-308 K), humidity as fraction (0.23-0.93)
- Stage 3: analysis data with `reference_datetime = NaT`
- Parquet files match expected partition scheme

#### Key Differences from R Pipeline:
- **No Stage 1 intermediate**: dynamical.org provides site-extracted data directly
- **Precipitation**: dynamical's `precipitation_surface` is already `kg/m²/s` (units attr `kg m-2 s-1`, equivalent to mm/s), so it maps **directly** with no conversion (R pipeline divided 6h accumulation by 21600s). ⚠️ An earlier version of this pipeline divided by 1000, which made precip ~1000× too small — fixed; the transform is now identity.
- **Temperature**: dynamical gives °C, add 273.15 for K (R pipeline added 273)
- **Grid cell selection**: dynamical's nearest-neighbor may differ from gefs4cast at boundary sites (see Phase 1 results)

### Phase 3: S3 Upload & Integration

S3 upload not yet implemented in `write_parquet.py`. Needs:
- S3 write using `pyarrow.fs.S3FileSystem` with OSN credentials
- Integration with existing bucket paths in `challenge_configuration.yaml`
- Incremental Stage 3 updates (append new data, replace last 3 days)

Output parquet schema (verified matching current pipeline):

```
Columns:
- site_id: str (e.g., "USGS-14211720")
- datetime: timestamp (hourly)
- variable: str (CF convention names)
- prediction: float
- parameter: int (ensemble member number, 0-30)
- reference_datetime: timestamp (for stage2) or NaT (stage3)
- family: str ("ensemble")
```

Partition structure:
```
# Stage2
drivers/usgsrc4cast/noaa/gefs-v12/stage2/
  reference_datetime=YYYY-MM-DD/
    site_id=USGS-########/
      part-0.parquet

# Stage3
drivers/usgsrc4cast/noaa/gefs-v12/stage3/
  site_id=USGS-########/
    part-0.parquet
```

### Phase 4: Parallel Run & Validation
1. Run both old (gefs4cast) and new (dynamical) pipelines in parallel
2. Compare outputs at each stage
3. Validate statistical properties match
4. Monitor for edge cases (missing data, ensemble handling)

### Phase 5: Cutover
1. Update GitHub Actions workflows to use new Python scripts
2. Deprecate R-based driver scripts
3. Document any breaking changes

---

## Key Processing Steps to Replicate

### 1. Temperature Unit Conversion
**Current**: GEFS provides temperature in Kelvin, code adds 273 (appears incorrect)
**Dynamical**: Temperature is in °C
**Action**: Add 273.15 to convert °C → K

```python
temperature_k = ds["temperature_2m"] + 273.15
```

### 2. Solar Geometry Correction (for DSWRF)
Current logic in `to_hourly.R:67-81`:
- Calculate potential solar radiation using solar zenith angle
- Redistribute daily SW total according to solar geometry
- Preserves daily totals while adjusting hourly distribution

```python
# Python equivalent needed - see downscale_solar_geom() in to_hourly.R
def apply_solar_geometry(dswrf, datetime, lat, lon):
    # Calculate potential radiation using solar constant (1366 W/m²)
    # Compute daily averages
    # Redistribute: rpot * (avg_SW / avg_rpot)
    pass
```

### 3. Precipitation Rate Conversion
**Current**: `APCP / (6 * 60 * 60)` to convert 6-hour accumulated to per-second rate
**Dynamical**: `precipitation_surface` is already in mm/s (average rate since previous step)
**Action**: **No conversion needed!** Direct mapping.

### 4. Relative Humidity Conversion
**Current**: Divide by 100 to convert % to fraction
**Dynamical**: `relative_humidity_2m` is in %
**Action**: Divide by 100

```python
rh_fraction = ds["relative_humidity_2m"] / 100
```

### 5. State Variable Interpolation
- Linear interpolation from 3-hourly to 1-hourly for: TMP, PRES, RH, UGRD, VGRD
- Use `xarray.interp()` or `scipy.interpolate` in Python
- Note: Dynamical is 3-hourly (days 0-10) and 6-hourly (days 10-35)

```python
# Example: interpolate to hourly
hourly_times = pd.date_range(start, end, freq='1H')
ds_hourly = ds.interp(time=hourly_times, method='linear')
```

### 6. Horizon Filtering
Current logic filters certain horizons (003, 006) - this was specific to GRIB file structure.
**Dynamical**: Uses `lead_time` dimension directly, no horizon codes.
**Action**: Filter by `lead_time` values instead if needed.

---

## Open Questions

### Resolved

1. ~~**Ensemble handling**: Does dynamical provide all 31 GEFS ensemble members? How are they indexed?~~
   - ✅ **Yes**: 31 members indexed 0-30 via `ensemble_member` dimension

2. ~~**Historical coverage**: Does dynamical analysis go back to 2020-09-24?~~
   - ✅ **Analysis**: Goes back to 2000-01-01 (much further!)
   - ⚠️ **Forecast**: Starts 2020-10-01 (7 days later than current 2020-09-24)

3. ~~**RH variable**: Is relative humidity directly available?~~
   - ✅ **Yes**: `relative_humidity_2m` available (but only after 2020-01-01)

4. ~~**Pressure variable**: Which pressure variable should we use?~~
   - ✅ **Use `pressure_surface`** (Pa) - matches current pipeline

5. ~~**Temporal resolution**: Is dynamical data already hourly?~~
   - ✅ **No**: 3-hourly (days 0-10), 6-hourly (days 10-35) - still need to interpolate to hourly

### Also Resolved

6. ~~**Update latency**: How quickly is dynamical updated after NOAA releases new forecasts?~~
   - ✅ Update latency is small - not a concern for operational pipeline

7. ~~**Gap period**: Forecast data starts 2020-10-01, but current pseudo starts 2020-09-24~~
   - ✅ **Not an issue** - existing forecasts are already stored on S3, no need to overwrite historical data

8. ~~**Only 00 UTC forecasts**: Dynamical only archives 00:00 UTC init times~~
   - ✅ **Compatible** - the challenge only uses 00 UTC forecasts

9. ~~**Grid cell selection**: Do dynamical.org and gefs4cast select the same nearest grid cells?~~
   - ⚠️ **Not always** — see Phase 1 Validation Results below

### Remaining Questions

1. **Rate limiting**: Any API limits or best practices for bulk downloads?
   - Contact feedback@dynamical.org if issues arise
   - Monitor during Phase 1 validation

---

## Phase 1 Validation Results

**Script:** `python/validate_dynamical_migration.py`

Compared dynamical.org GEFS forecast data against current Stage 1 (gefs4cast) parquet data
on S3 at native 3-hourly resolution, per-ensemble-member. Both are raw GEFS v12 model output.

### Grid Cell Selection Differences

Both sources use a 0.25° GEFS grid, but nearest-neighbor rounding differs at grid cell
boundaries. Dynamical matched grid cells:

| Site | Requested (lat, lon) | Dynamical matched | gefs4cast matched (inferred) |
|------|---------------------|-------------------|------------------------------|
| USGS-14211720 | 45.5175, -122.6692 | 45.50, -122.75 | 45.50, -122.50 (same as 14211010) |
| USGS-14211010 | 45.3793, -122.5773 | 45.50, -122.50 | 45.50, -122.50 |
| USGS-14181500 | 44.7538, -122.2974 | 44.75, -122.25 | Different cell (~400m higher elevation) |

**Evidence:** USGS-14211720 and USGS-14211010 have **identical** Stage 1 values in the
current pipeline (TMP mean=17.73, PRES mean=99237.08), confirming gefs4cast mapped both
to the same grid cell. Dynamical correctly maps them to different cells.

### Per-Site Comparison (Forecast vs Stage 1)

**USGS-14211010 (same grid cell — baseline for comparison):**
| Variable | mean_diff | max_diff | Notes |
|----------|-----------|----------|-------|
| TMP | -0.002°C | 0.15°C | Near-perfect |
| PRES | -0.3 Pa | 32.6 Pa | Rounding only |
| RH | 0.004% | 0.33% | Near-perfect |
| UGRD | 0.0001 m/s | 0.07 m/s | Near-perfect |
| VGRD | 0.0002 m/s | 0.06 m/s | Near-perfect |
| DSWRF | 0.009 W/m² | 2.0 W/m² | Near-perfect |
| DLWRF | 0.006 W/m² | 1.7 W/m² | Near-perfect |

**USGS-14211720 (different grid cell — longitude boundary):**
| Variable | mean_diff | max_diff | Notes |
|----------|-----------|----------|-------|
| TMP | +1.39°C | 3.09°C | Grid cell at -122.75 vs -122.50 |
| PRES | +1024 Pa | 1077 Pa | ~80m elevation difference |
| RH | -7.3% | 17.4% | Different local humidity |

**USGS-14181500 (different grid cell — mountain terrain):**
| Variable | mean_diff | max_diff | Notes |
|----------|-----------|----------|-------|
| TMP | -1.87°C | 5.09°C | Higher elevation cell |
| PRES | -4682 Pa | 4774 Pa | ~400m elevation difference |
| RH | +2.4% | 25.9% | Different local humidity |

### Conclusions

1. **When grid cells match, data is nearly identical** — validates that dynamical.org and
   gefs4cast are processing the same underlying GEFS data correctly
2. **Grid cell differences are the sole source of discrepancy** — not timezone, variable
   definition, or processing differences
3. **Dynamical's grid cell selections are at least as valid** as gefs4cast's (and arguably
   better for USGS-14211720, which dynamical correctly assigns to a distinct cell)
4. **Acceptable for migration** — forecast models will see slightly different driver values
   at ~2-3 sites, but this is within the natural uncertainty of using gridded weather data
   for point locations

### Phase 1 Checklist

- [x] All 10 USGS sites return valid data from dynamical
- [x] Variable values match current pipeline when same grid cell is selected
- [x] Ensemble members correctly mapped (0-30)
- [x] Grid cell selection differences understood and documented
- [ ] Solar geometry correction produces same DSWRF distribution (Phase 2)
- [ ] Parquet output schema matches exactly (Phase 2)
- [ ] S3 upload works to correct paths (Phase 3)
- [ ] GitHub Actions workflow runs successfully (Phase 5)
- [ ] No regressions in downstream forecast models (Phase 4)

---

## References

### Dynamical.org Documentation
- [GEFS Analysis Reference](dynamical_gefs_analysis.md) - Historical analysis dataset
- [GEFS Forecast Reference](dynamical_gefs_forecast.md) - 35-day ensemble forecasts
- https://dynamical.org/catalog/noaa-gefs-analysis/
- https://dynamical.org/catalog/noaa-gefs-forecast-35-day/

### Current Implementation
- https://github.com/eco4cast/gefs4cast/tree/main
- Current Python utilities: `python/dynamical_utils.py`
- Current R processing: `R/eco4cast-helpers/to_hourly.R`
- Driver scripts: `drivers/*.R`
- Challenge config: `challenge_configuration.yaml`
