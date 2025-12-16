# Catalog Workflow Fix - December 2025

## Problem

The catalog GitHub Actions workflow started failing on **September 23, 2025** with the following error:

```
Error in file(con, "w") : cannot open the connection
cannot open file '../catalog/forecasts//collection.json': No such file or directory
```

## Root Cause

On September 23, 2025, the `stac4cast` package merged PR #121 which changed how destination paths are handled. The package now **automatically prepends `../`** to all destination paths:

```r
# Before (stac4cast PR #121)
dest <- destination_path

# After (stac4cast PR #121)
dest <- paste0("../", destination_path)
```

### Why This Broke Our Workflow

Our original setup:
- **Scripts ran from**: Repository root (`/path/to/usgsrc4cast-ci/`)
- **Config paths**: `forecast_path: 'catalog/forecasts/'`
- **Package behavior (before)**: Used paths as-is → wrote to `catalog/forecasts/` ✓
- **Package behavior (after)**: Prepended `../` → tried to write to `../catalog/forecasts/` ✗

When running from repo root, `../catalog/forecasts/` attempts to access the parent directory of the repository, which doesn't exist in the GitHub Actions environment.

## The Solution

The fix involves three coordinated changes to make the scripts run from the `catalog/` directory, so the `../` prefix correctly navigates back to the repo root:

### 1. Add `catalog_path` Configuration

**File**: `challenge_configuration.yaml`

```yaml
catalog_config:
  catalog_path: 'catalog'
  # ... rest of config
```

This tells the stac4cast package where the catalog directory is located.

### 2. Update GitHub Actions Workflow

**File**: `.github/workflows/catalog.yaml`

Changed all catalog rendering steps from:
```yaml
- name: Render
  shell: Rscript {0}
  run: source('catalog/forecasts/forecast_models.R')
```

To:
```yaml
- name: Render
  shell: bash
  run: |
    cd catalog
    Rscript -e "source('forecasts/forecast_models.R')"
```

This makes the scripts run from the `catalog/` directory instead of repo root.

### 3. Update R Scripts Config Loading

**Files**: All catalog R scripts (`catalog/**/*.R`)

Changed from:
```r
config <- yaml::read_yaml('challenge_configuration.yaml')
```

To:
```r
config <- yaml::read_yaml('../challenge_configuration.yaml')
```

Since scripts now run from `catalog/`, they need to go up one directory to find the config file.

**Also updated** `catalog/catalog.R` source statements from:
```r
source("catalog/R/catalog-common.R")
source('catalog/R/stac_functions.R')
```

To:
```r
source("R/catalog-common.R")
source('R/stac_functions.R')
```

## How It Works Now

With the fix in place:

1. **Working directory**: `catalog/` (one level down from repo root)
2. **Config path**: `'catalog/forecasts/'` (in configuration)
3. **Package prepends**: `../` → becomes `'../catalog/forecasts/'`
4. **Actual path**: From `catalog/`, going up (`../`) to repo root, then down to `catalog/forecasts/` ✓

## Additional Fixes Required

After the initial fix, several edge cases needed addressing:

### 4. Fix Hardcoded Paths in model_metadata.R

**File**: `catalog/model_metadata.R`

The script had hardcoded "catalog" prefixes when writing files:
```r
# Before
jsonlite::write_json(metadata, path = file.path("catalog", file_name), pretty = TRUE)
minioclient::mc_cp(file.path("catalog", file_name), file.path("osn", config$model_metadata_bucket, file_name))

# After
jsonlite::write_json(metadata, path = file_name, pretty = TRUE)
minioclient::mc_cp(file_name, file.path("osn", config$model_metadata_bucket, file_name))
```

### 5. Update site_table Path

**File**: `challenge_configuration.yaml`

Changed from:
```yaml
site_table: USGS_site_metadata.csv
```

To:
```yaml
site_table: ../USGS_site_metadata.csv
```

Since scripts run from `catalog/` but the CSV is in repo root, the `../` prefix is needed.

**Files affected**: `catalog/noaa_forecasts/noaa_forecasts.R` and `catalog/sites/build_sites_page.R` use `config$site_table` to read this file.

### 6. Adjust Paths Based on Which Functions Were Updated

**IMPORTANT**: Not all stac4cast functions were updated in PR #121. Only these 5 functions prepend `../`:
- `build_forecast_scores()` - Used by scores
- `build_sites()` - Used by sites
- `build_forecast()` - Used by forecasts
- `build_summaries()` - Used by summaries
- `build_noaa()` - Used by noaa_forecasts

These 2 functions were NOT updated (don't prepend `../`):
- `build_inventory()` - Used by inventory
- `build_targets()` - Used by targets

**Configuration adjustments**:
```yaml
# Functions that ADD ../
forecast_path: 'catalog/forecasts/'    # build_forecast adds ../
scores_path: 'catalog/scores/'         # build_forecast_scores adds ../
summaries_path: 'catalog/summaries/'   # build_summaries adds ../
noaa_path: 'catalog/noaa_forecasts/'   # build_noaa adds ../
site_path: 'catalog/sites'             # build_sites adds ../

# Functions that DON'T add ../
inventory_path: 'inventory'            # build_inventory doesn't add ../
targets_path: 'catalog/targets/'       # build_targets doesn't add ../ (but still uses catalog/ prefix)
```

### 7. Fix catalog.R Destination Path

**File**: `catalog/catalog.R`

Changed from:
```r
dest <- "catalog/"
```

To:
```r
dest <- "."
```

Since the script already runs from the `catalog/` directory, using "." correctly references the current directory.

## Files Changed

- `challenge_configuration.yaml` - Added `catalog_path` setting, updated `site_table` path, adjusted `inventory_path`
- `.github/workflows/catalog.yaml` - Updated all render steps to run from catalog directory
- `catalog/catalog.R` - Updated config path, source statements, and dest path
- `catalog/forecasts/forecast_models.R` - Updated config path
- `catalog/scores/scores_models.R` - Updated config path
- `catalog/summaries/summaries_models.R` - Updated config path
- `catalog/inventory/create_inventory_page.R` - Updated config path
- `catalog/noaa_forecasts/noaa_forecasts.R` - Updated config path
- `catalog/targets/create_targets_page.R` - Updated config path
- `catalog/sites/build_sites_page.R` - Updated config path
- `catalog/model_metadata.R` - Updated config path and removed hardcoded "catalog" prefixes

## Verification

After applying the fix, the catalog workflow should:
1. Successfully create all STAC collection.json files
2. No longer show "cannot open file" errors
3. Properly write catalog files to the `catalog/` directory structure

All workflow jobs should pass:
- ✓ render_forecasts
- ✓ render_scores
- ✓ render_summaries
- ✓ render_noaa
- ✓ render_inventory
- ✓ render_targets_sites
- ✓ metadata_catalog

## Troubleshooting

### Error: "cannot open file 'catalog/something.json'"

This suggests a script is trying to write with a hardcoded "catalog" prefix while already running from the catalog directory. Check for:
- Hardcoded paths in the script itself
- Functions that weren't updated in stac4cast PR #121 (use paths without `catalog/` prefix)

### Error: "cannot open file '../catalog/something.json'" (with ../)

This suggests:
- Either the script is running from the wrong directory (should be `catalog/`)
- Or the function WAS updated to add `../` and the path needs the `catalog/` prefix

### Error: "No such file or directory" for CSV files

Check if the file is in repo root but the script runs from `catalog/`. If so, add `../` prefix to the path in `challenge_configuration.yaml`.

### Which stac4cast functions add `../`?

To verify, check the stac4cast source code at commit from Sept 23, 2025:
- Functions with `dest <- paste0("../", destination_path)` → need `catalog/` prefix in config
- Functions without this line → need paths without `catalog/` prefix

## Related Changes in Other Repositories

The `neon4cast-ci` repository made similar changes on September 23-24, 2025:
- Removed `../` prefix from their config paths (since stac4cast now adds it)
- Their paths changed from `'../neon4cast-catalog/catalog/forecasts'` to `'neon4cast-catalog/catalog/forecasts'`

## References

- **stac4cast PR #121**: "update destination paths" - https://github.com/eco4cast/stac4cast/pull/121
- **Merge date**: September 23, 2025 at 15:56 UTC
- **neon4cast-ci commits**: Search for "catalog" changes on Sept 23-24, 2025
- **Related paper**: Thomas et al. 2023, Frontiers in Ecology and Environment (https://doi.org/10.1002/fee.2616)
