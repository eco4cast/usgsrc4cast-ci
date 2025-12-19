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

### Endpoints
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
import xarray as xr

# Analysis (for pseudo/stage3)
zarr = xr.open_zarr(
    "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=YOUR_EMAIL",
    chunks=None,
    decode_timedelta=True
)

# Forecast (for stage2)
zarr = xr.open_zarr(
    "https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=YOUR_EMAIL",
    chunks='auto',
    decode_timedelta=True
)
```

### Important Notes
- **Forecast init times**: Only 00:00 UTC forecasts are archived (not 06, 12, 18 UTC)
- **Interpolation**: 0.5° data is bilinearly interpolated to 0.25° for consistency
- **Forecast start date**: 2020-10-01, slightly later than current pseudo (2020-09-24)

---

## Migration Strategy

### Phase 1: Exploration & Validation
1. **Inspect dynamical zarr stores** to confirm:
   - All required variables are available
   - Ensemble member handling (how many, dimension structure)
   - Temporal coverage matches needs (2020-09-24 onward)
   - Spatial resolution and coordinate system

2. **Download sample data** for one site and compare against current pipeline output

### Phase 2: Build New Pipeline Components

#### New Python Scripts Needed:

**`python/drivers/download_dynamical.py`** - Main download orchestrator
- Replaces: `download_stage1_pseudo.R`
- Functions:
  - `download_analysis()` - Get analysis data for pseudo/stage3
  - `download_forecast()` - Get operational forecast for stage2

**`python/drivers/process_to_hourly.py`** - Hourly processing
- Port logic from `R/eco4cast-helpers/to_hourly.R`
- Include solar geometry calculations
- Handle variable transformations

**`python/drivers/write_parquet.py`** - Output formatting
- Convert xarray to pandas DataFrame
- Write partitioned parquet matching current structure
- Handle S3 upload

### Phase 3: Output Schema Alignment

Final parquet files must match current schema:

```
Columns:
- site_id: str (e.g., "USGS-14211720")
- datetime: timestamp (hourly)
- variable: str (CF convention names)
- prediction: float
- parameter: int (ensemble member number, 0-30)
- reference_datetime: timestamp (for stage2)
- family: str
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

### Remaining Questions

1. **Rate limiting**: Any API limits or best practices for bulk downloads?
   - Contact feedback@dynamical.org if issues arise
   - Monitor during Phase 1 validation

---

## Testing Checklist

- [ ] All 10 USGS sites return valid data from dynamical
- [ ] Variable values match current pipeline within tolerance
- [ ] Ensemble members correctly mapped (0-30)
- [ ] Solar geometry correction produces same DSWRF distribution
- [ ] Parquet output schema matches exactly
- [ ] S3 upload works to correct paths
- [ ] GitHub Actions workflow runs successfully
- [ ] No regressions in downstream forecast models

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
