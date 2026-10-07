# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **EFI-USGS River Chlorophyll Forecasting Challenge** cyberinfrastructure repository. It manages a complete forecasting challenge workflow including target generation, submission processing, weather driver downloads, baseline forecasts, scoring, dashboard generation, and STAC catalog creation. The challenge forecasts chlorophyll-a (chla) concentrations at USGS stream monitoring sites.

The repo is forked from the NEON Ecological Forecasting Challenge (`eco4cast/neon4cast-ci`). See [https://doi.org/10.1002/fee.2616](https://doi.org/10.1002/fee.2616) for background on forecasting challenge structure.

## Configuration

All challenge-specific settings are centralized in `challenge_configuration.yaml`:
- S3 bucket endpoints and paths for data storage
- Site metadata locations
- STAC catalog configuration
- Variable groups (currently only `aquatics` with `chla` variable at `P1D` duration)
- NOAA forecast driver paths (pseudo, stage1-stats, stage1, stage2, stage3)

When updating configuration, distinguish between settings that are infrastructure-specific (endpoints, buckets) versus challenge-specific (sites, variables, thresholds).

## Repository Structure

### `/targets`
Generates daily target observations by downloading USGS NWIS chlorophyll-a data.

**Key files:**
- `_targets.R`: Defines the targets pipeline using the `targets` package
- `src/download_nwis_data.R`: NWIS data retrieval functions
- `in/FY23_ecological_forecast_challenge_USGS_sites.csv`: Site list
- `in/pcodes.yml`: USGS parameter codes for chlorophyll measurements

**Data sources:**
- Daily values (dv) service for most sites
- Unit values (uv) service for sites without daily data
- Special handling for RFU (Relative Fluorescence Units) conversion for specific WRB sites (14211720, 14211010, 14181500) that switched from ug/L sensors to RFU sensors in 2024

**Output:** `river-chl-targets.csv.gz` pushed to S3 targets bucket

### `/submission_processing`
Processes forecast submissions from the submissions bucket.

**Key file:** `process_submissions.R`

**Processing steps:**
1. Downloads files from submissions bucket (`submit.ecoforecast.org`)
2. Validates forecast format using `forecast_output_validator()`
3. Extracts metadata (model_id, reference_datetime) from filenames
4. Writes forecasts to parquet format partitioned by project_id/duration/variable/model_id/reference_date
5. Generates forecast summaries (mean, median, quantiles)
6. Updates inventory catalog with new submission metadata
7. Moves raw submissions to archive with timestamp

File naming convention: `{project_id}-{YYYY-MM-DD}-{model_id}-{filename}.csv.gz`

### `/scoring`
Scores submitted forecasts against targets using CRPS and log score metrics.

**Key file:** `scoring.R`

**Process:**
- Uses `score4cast` package for standardized scoring
- Maintains provenance tracking to avoid re-scoring
- Scores are calculated per variable/duration combination
- Parallel processing with configurable cores (default: 8)
- Lookback window: past 365 days
- Outputs written to scores bucket in parquet format

### `/baseline_models`
Generates baseline/null model forecasts for comparison.

**Key file:** `run_aquatics_baselines.R`

**Models:**
- **Climatology** (`aquatics_climatology.R`): Day-of-year average from historical data
- **Persistence Random Walk** (`aquatics_persistenceRW.R`): Uses fable package for time series forecasting

**Helper functions:**
- `R/fablePersistenceModelFunction.R`: Shared persistence model logic
- These models must be registered separately for each challenge

### `/drivers`
Manages NOAA GEFS weather forecast drivers.

> **Migration in Progress:** The drivers pipeline is being migrated from R/gefs4cast (GRIB file processing) to Python/dynamical.org (pre-processed zarr store). See `docs/migrate_to_dynamical.md` for details.

**Current R-based files (legacy):**
- `download_stage1_pseudo.R`: Downloads pseudo-historical NOAA data
- `generate_stage2.R`: Generates stage2 processed drivers
- `generate_stage3.R`: Converts to hourly resolution with site-specific data
- `update_stage3.R`: Updates existing stage3 drivers

**Processing pipeline (3 stages):**
1. **Stage1**: Raw NOAA GEFS v12 forecasts extracted at site coordinates (31 ensemble members)
2. **Stage2**: Hourly interpolated forecasts with CF convention variable names
3. **Stage3**: Pseudo-historical nowcast combining multiple forecast cycles

**Variables:**
- Stage1 (GRIB names): TMP (°C), RH (%), PRES (Pa), UGRD, VGRD (m/s), APCP (kg/m²), DSWRF, DLWRF (W/m²)
- Stage2/3 (CF names): air_temperature (K), relative_humidity (fraction), air_pressure (Pa), northward_wind, eastward_wind (m/s), precipitation_flux (kg/m²/s), surface_downwelling_shortwave/longwave_flux_in_air (W/m²)

**Key transformations (Stage1 → Stage2):**
- Temperature: TMP + 273 (°C → K)
- Humidity: RH / 100 (% → fraction)
- Precipitation: APCP / (6*3600) (accumulated → rate)
- Shortwave radiation: Solar geometry correction applied

### `/catalog`
Builds STAC (SpatioTemporal Asset Catalog) for data discovery.

**Key file:** `catalog.R` - Main catalog builder

**Subdirectories:**
- `forecasts/`: Forecast model collections
- `scores/`: Scoring results collections
- `targets/`: Target observations
- `sites/`: Site metadata
- `noaa_forecasts/`: NOAA driver collections
- `summaries/`: Forecast summary statistics
- `inventory/`: Submission inventory
- `thumbnail_plots/`: Visualization thumbnails

**R helpers:**
- `R/stac_functions.R`: STAC item/collection builders
- `R/catalog-common.R`: Shared utilities

### `/dashboard`
Quarto website for challenge dashboard.

**Key files:**
- `_quarto.yml`: Quarto configuration
- `R/build_dashboard_sites.R`: Site-specific page generation
- `R/flare-plots.R`: Forecast visualization functions

**Output:** Static website published to GitHub Pages

### `/R/eco4cast-helpers`
Shared utilities across the challenge infrastructure:
- `forecast_output_validator.R`: Validates submission format
- `submit.R`: Submission helpers
- `noaa_gefs.R`: NOAA data access
- `s3_helpers.R`: S3 bucket interactions
- `fable_helpers.R`: Time series modeling utilities
- `to_hourly.R`: Temporal aggregation for drivers

### `/python`
Python implementations of key utilities:
- `forecast_output_validator.py`: Python version of validator
- `noaa_gefs.py`: NOAA data access
- `submit.py`: Submission helpers
- `dynamical_utils.py`: Utilities for accessing dynamical.org GEFS zarr stores (for migration)
- `validate_dynamical_migration.py`: Phase 1 validation comparing dynamical.org vs gefs4cast Stage 1

### `/python/drivers`
New Python-based GEFS driver pipeline (replacing R/gefs4cast):
- `download_dynamical.py`: CLI orchestrator for generating Stage 1/2/3 from dynamical.org
- `process_to_native.py`: Native-resolution Stage 1 + stage1-stats (GRIB names, per-ensemble)
- `process_to_hourly.py`: Hourly interpolation, solar geometry correction, variable transforms
- `solar_geometry.py`: Solar zenith angle and potential radiation calculations (ported from `to_hourly.R`)
- `write_parquet.py`: Write partitioned parquet (local or OSN S3) matching Stage 1/2/3 schema

Products produced: **stage1**, **stage1-stats**, **stage2**, **stage3**. The gefs4cast
**pseudo** product is **deprecated** (dynamical.org can't reproduce its 31-member,
4-cycle short-horizon structure). Stage 1 carries **16 of 25** GRIB variables — the 9
land-surface/flux vars dynamical doesn't ingest (ICETK, LHTFL, SHTFL, SNOD, SOILW,
TSOIL, ULWRF, USWRF, WEASD) are dropped. Stage 3 is single-member (deterministic
analysis) vs 31-member in the old pseudo-derived product.

**CLI usage:**
```bash
# Generate Stage 1 + stage1-stats forecast for a date
python -m python.drivers.download_dynamical stage1 --date 2025-09-07

# Generate Stage 2 forecast for a date
python -m python.drivers.download_dynamical stage2 --date 2025-09-07

# Generate/update Stage 3 analysis data
python -m python.drivers.download_dynamical stage3 --start 2025-09-01 --end 2025-09-07

# One-shot historical backfill (stage1/stage2 accept --start/--end)
python -m python.drivers.download_dynamical stage1 --start 2026-09-18 --end 2026-10-06

# Write to the production OSN bucket (CI only; needs OSN_KEY/OSN_SECRET)
python -m python.drivers.download_dynamical stage2 --s3
```

S3 writes to OSN require OSN_KEY/OSN_SECRET, which exist only as GitHub Actions secrets
(eco4cast org) — so the `--s3` path runs in CI (`.github/workflows/drivers_python.yaml`),
not locally. Local runs use `--output` directories.

### `/docs`
Project documentation:
- `migrate_to_dynamical.md`: Migration plan from gefs4cast to dynamical.org
- `dynamical_gefs_analysis.md`: Reference for dynamical.org GEFS analysis dataset
- `dynamical_gefs_forecast.md`: Reference for dynamical.org GEFS 35-day forecast dataset
- `usgsrc4cast_gefs_documentation.Rmd`: Current GEFS data format documentation with examples
- `CATALOG_WORKFLOW_FIX.md`: Details on stac4cast breaking change workaround

## Development Commands

### Running target generation locally
```bash
cd targets
Rscript -e "targets::tar_make()"
```

### Running baseline models
```bash
Rscript baseline_models/run_aquatics_baselines.R
```

### Processing submissions manually
```bash
Rscript submission_processing/process_submissions.R
```

### Running scoring
```bash
Rscript scoring/scoring.R
```

### Building catalog
```bash
Rscript catalog/catalog.R
```

### Building dashboard locally
```bash
cd dashboard
quarto render
```

### Checking targets pipeline status
```bash
cd targets
Rscript -e "targets::tar_visnetwork()"
Rscript -e "targets::tar_outdated()"
```

## GitHub Actions Workflows

Located in `.github/workflows/`:

- `targets.yaml`: Daily target generation (4 AM UTC cron)
- `baselines_daily.yaml`: Daily baseline forecast generation
- `combined.yaml`: Processes submissions + scores + updates catalog
- `catalog.yaml`: Rebuilds STAC catalog
- `drivers_stage1.yaml`: Downloads NOAA stage1 drivers
- `drivers_stage3.yaml`: Generates hourly stage3 drivers
- `docker_*.yaml`: Build Docker containers for reproducibility

**Container images:**
- `eco4cast/usgsrc4cast-targets:latest`: Target generation environment
- `eco4cast/usgsrc4cast-python:latest`: Python utilities
- Custom containers for specific workflows

All workflows use secrets for S3 access:
- `OSN_KEY` / `OSN_SECRET`: Object Storage Network credentials
- `AWS_ACCESS_KEY_SUBMISSIONS` / `AWS_SECRET_ACCESS_KEY_SUBMISSIONS`: Submission bucket access

Workflows are disabled by default when forking and must be manually enabled.

## Data Storage Architecture

All data stored in S3-compatible object storage (OSN at SDSC):

**Main buckets:**
- `forecasts`: Submitted forecasts (parquet + raw archives)
- `targets`: Target observation data
- `scores`: Scoring results
- `inventory`: Submission metadata and catalogs
- `drivers`: NOAA GEFS forecast drivers
- `summaries`: Aggregated forecast statistics
- `prov`: Provenance tracking for idempotent operations
- `metadata/model_id`: Model metadata from Google Sheets
- `archive`: Snapshots and archival data

**Partitioning scheme:**
Most datasets partitioned by: `project_id={project_id}/duration={duration}/variable={variable}/model_id={model_id}/reference_date={reference_date}`

## Key Dependencies

**R packages:**
- `targets`: Pipeline orchestration
- `score4cast`: Forecast scoring (custom package from eco4cast)
- `stac4cast`: STAC catalog generation (custom package from eco4cast)
- `read4cast`: Forecast file I/O (implied from neon4cast package)
- `minioclient`: S3 operations
- `arrow`: Parquet I/O and S3 access
- `fable`: Time series forecasting for baselines
- `dataRetrieval`: USGS NWIS data access
- `gefs4cast`: NOAA GEFS driver processing
- `quarto`: Dashboard rendering

**Custom remotes (in DESCRIPTION):**
```
github::eco4cast/score4cast
github::cboettig/minioclient
github::eco4cast/neon4cast
github::eco4cast/stac4cast
```

## Critical: stac4cast Breaking Change (September 2025)

**IMPORTANT**: On September 23, 2025, the `stac4cast` package introduced a breaking change (PR #121) that affects how catalog scripts must be run.

**What changed**: The package now automatically prepends `../` to *some* destination paths:
```r
dest <- paste0("../", destination_path)  # Added in stac4cast PR #121
```

**CRITICAL DETAIL**: Only 5 out of 7 stac4cast functions were updated in PR #121:
- **Updated (add `../`)**: `build_forecast()`, `build_forecast_scores()`, `build_summaries()`, `build_noaa()`, `build_sites()`
- **NOT updated**: `build_inventory()`, `build_targets()`

**Required setup**:
1. **Catalog scripts must run from `catalog/` directory** (not repo root)
2. **Config must be loaded with `../` prefix**: `yaml::read_yaml('../challenge_configuration.yaml')`
3. **Workflow must `cd catalog` before running scripts**
4. **Paths in config must account for which function is used**:
   ```yaml
   # Functions that ADD ../
   forecast_path: 'catalog/forecasts/'    # build_forecast adds ../
   scores_path: 'catalog/scores/'         # build_forecast_scores adds ../
   summaries_path: 'catalog/summaries/'   # build_summaries adds ../
   noaa_path: 'catalog/noaa_forecasts/'   # build_noaa adds ../
   site_path: 'catalog/sites'             # build_sites adds ../

   # Functions that DON'T add ../
   inventory_path: 'inventory'            # build_inventory doesn't add ../
   targets_path: 'catalog/targets/'       # Still needs catalog/ (unclear why)
   ```

**Additional required changes**:
- `site_table: ../USGS_site_metadata.csv` (file in repo root, scripts run from catalog/)
- `catalog/catalog.R` must use `dest <- "."` (not `dest <- "catalog/"`)
- Remove hardcoded "catalog" prefixes from file operations in scripts

**Why**: With the `../` prefix added by stac4cast:
- Running from `catalog/` directory
- Package prepends `../` to `'catalog/forecasts/'`
- Results in `../catalog/forecasts/` which navigates up to repo root, then down to `catalog/forecasts/` ✓

**Affected files**:
- All catalog R scripts load config with: `yaml::read_yaml('../challenge_configuration.yaml')`
- All workflow render steps run with: `cd catalog && Rscript -e "source('...')"`

**See**: `docs/CATALOG_WORKFLOW_FIX.md` for complete details, troubleshooting guide, and verification steps.

## Important Notes

- Project ID: `usgsrc4cast`
- Duration: `P1D` (daily forecasts only)
- Variable: `chla` (chlorophyll-a in µg/L)
- Site IDs format: `USGS-{site_number}` (e.g., `USGS-14211720`)
- Forecast horizon: Typically 30-35 days ahead
- Self-hosted GitHub runners can be added by Quinn or Carl (see PR #17)
- Challenge registration: https://forms.gle/kg2Vkpho9BoMXSy57
- Model metadata tracked in Google Sheet (see `challenge_configuration.yaml`)

## Architecture Patterns

**Forecast submission flow:**
1. User submits to submissions bucket →
2. `combined.yaml` workflow triggers →
3. Validation →
4. Parquet conversion + summary generation →
5. Inventory update →
6. Scoring (when targets available) →
7. Catalog rebuild →
8. Dashboard update

**Idempotency:**
Uses hash-based provenance tracking in scoring and other operations to avoid duplicate processing. Provenance files stored in prov bucket track which forecast/target combinations have been scored.

**Parallel processing:**
Scoring and driver generation use `future`/`furrr` for parallel execution. Configure workers based on available resources.

**Data validation:**
All submissions validated against schema before processing. Invalid submissions archived but not processed. Use `forecast_output_validator()` to check format before submission.

## Active Migration: GEFS Drivers to dynamical.org

The NOAA GEFS driver pipeline is being migrated from the R-based gefs4cast approach (downloading and processing GRIB files) to using pre-processed data from dynamical.org's zarr stores.

**Why migrate:**
- Significantly more efficient (no GRIB file processing)
- dynamical.org already extracts and processes GEFS data
- Reduces infrastructure complexity and maintenance burden

**dynamical.org endpoints:**
```
Analysis:  https://data.dynamical.org/noaa/gefs/analysis/latest.zarr
Forecast:  https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr
```

**Key mappings:**
| Current Stage | dynamical.org Source | Notes |
|---------------|---------------------|-------|
| pseudo/stage3 | GEFS Analysis | Historical nowcast data |
| stage2 | GEFS Forecast (35-day) | 31 ensemble members, 00 UTC only |

**Variable mapping (dynamical → challenge):**
- `temperature_2m` (°C) → `air_temperature` (K): add 273.15
- `relative_humidity_2m` (%) → `relative_humidity` (fraction): divide by 100
- `pressure_surface` (Pa) → `air_pressure` (Pa): direct
- `wind_u_10m`, `wind_v_10m` → `northward_wind`, `eastward_wind`: direct
- `precipitation_surface` (mm/s) → `precipitation_flux` (kg/m²/s): already a rate
- `downward_short_wave_radiation_flux_surface` → apply solar geometry correction
- `downward_long_wave_radiation_flux_surface` → direct

**Output compatibility:**
New pipeline must produce identical parquet schema to current Stage 2/3:
- Columns: `site_id`, `datetime`, `variable`, `prediction`, `parameter`, `reference_datetime`, `family`
- Partitioning: `reference_datetime={date}/site_id={site}` (stage2) or `site_id={site}` (stage3)

**Phase 1 Validation Results (completed):**
- Both dynamical.org and gefs4cast pull from the same GEFS v12 model
- Per-ensemble-member comparison of dynamical forecast vs current Stage 1 at native 3h resolution
- Sites where both sources select the same 0.25° grid cell show near-perfect agreement (e.g., USGS-14211010: TMP max_diff=0.15°C, wind max_diff=0.07 m/s)
- Some sites show systematic offsets due to **different nearest-neighbor grid cell selection** between dynamical.org and gefs4cast (e.g., USGS-14211720 longitude -122.669 rounds to -122.75 in dynamical but -122.50 in gefs4cast)
- Pressure offsets at mountain sites (USGS-14181500: ~4700 Pa) correspond to elevation differences between adjacent grid cells
- Grid cell differences are acceptable for the forecasting challenge — dynamical's selections are at least as valid
- Validation script: `python/validate_dynamical_migration.py`

**Phase 2 Pipeline (completed):**
- `python/drivers/` contains the full pipeline: download, hourly interpolation, solar geometry, variable transforms, parquet output
- State variables (TMP, PRES, RH, wind) use linear interpolation to hourly
- Flux variables (precip, radiation) use forward-fill to hourly
- Solar geometry correction redistributes shortwave radiation using potential radiation from solar zenith angle calculations
- Precipitation: dynamical's `precipitation_surface` is already in kg/m²/s (equivalent to mm/s), so it maps directly with no conversion (no accumulation conversion needed unlike gefs4cast)
- End-to-end tested: dynamical.org zarr -> hourly processing -> partitioned parquet matching Stage 2/3 schema

**Phase 3 S3 upload (completed):**
- `write_parquet.py` writes to OSN via `make_osn_filesystem()` (OSN_KEY/OSN_SECRET), targeting production bucket paths
- `process_to_native.py` adds stage1 + stage1-stats; output schema verified identical to the on-disk gefs4cast schema (`ensemble, cycle, horizon[duration s], datetime[us UTC], variable, prediction, family`; 31 members gec00/gep01-30 for stage1, geavg/gespr for stage1-stats)
- `.github/workflows/drivers_python.yaml` runs stage1/stage2/stage3 daily (12:00 UTC) via uv, writing to OSN; `workflow_dispatch` inputs drive one-shot backfills
- `pseudo` removed from `challenge_configuration.yaml` `noaa_forecast_groups`/`_group_paths`

**Migration status:** Phases 1–3 complete. Phase 4 (parallel run & validation against the R products) and Phase 5 (cutover: retire `drivers_stage1.yaml`/`drivers_stage3.yaml`) not yet started.

**Documentation:** See `docs/migrate_to_dynamical.md` for complete migration plan and status.
