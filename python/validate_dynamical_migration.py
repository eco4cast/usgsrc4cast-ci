"""
Phase 1 Validation Script: Compare dynamical.org GEFS vs current GEFS pipeline

Compares at the raw data level to avoid confounding from interpolation or
solar geometry corrections:

  TEST 1: dynamical.org forecast vs current Stage 1
    - Both are raw GEFS forecasts (3h/6h resolution, 31 ensemble members)
    - Compares per-ensemble-member values at matching timestamps
    - Uses GRIB-level variable names before any unit conversion

  TEST 2: dynamical.org analysis vs current Stage 1 (short horizon)
    - Analysis is single-realization; Stage 1 has ensembles
    - Compare analysis against ensemble mean at matching 3-hourly times

Usage:
    python validate_dynamical_migration.py

Requirements:
    pip install xarray zarr pandas pyarrow s3fs numpy
"""

import xarray as xr
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import warnings

warnings.filterwarnings('ignore', category=FutureWarning)


# =============================================================================
# Configuration
# =============================================================================

DYNAMICAL_ANALYSIS_URL = "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=jzwart@usgs.gov"
DYNAMICAL_FORECAST_URL = "https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=jzwart@usgs.gov"

CURRENT_S3_ENDPOINT = "https://sdsc.osn.xsede.org"
CURRENT_S3_BUCKET = "bio230014-bucket01/challenges/drivers/usgsrc4cast/noaa/gefs-v12"

SITE_METADATA_URL = "https://raw.githubusercontent.com/eco4cast/usgsrc4cast-ci/main/USGS_site_metadata.csv"

# Mapping: dynamical variable -> (stage1 GRIB variable name, transform dynamical -> stage1 units)
# Stage 1 units (verified from parquet): TMP in °C, RH in %, PRES in Pa,
# UGRD/VGRD in m/s, APCP in kg/m² accumulated, DSWRF/DLWRF in W/m²
VARIABLE_MAPPINGS = {
    "temperature_2m": ("TMP", lambda x: x),                    # both °C
    "pressure_surface": ("PRES", lambda x: x),                 # both Pa
    "relative_humidity_2m": ("RH", lambda x: x),               # both %
    "wind_u_10m": ("UGRD", lambda x: x),                       # both m/s
    "wind_v_10m": ("VGRD", lambda x: x),                       # both m/s
    "precipitation_surface": ("APCP", None),                    # rate vs accumulated - skip direct comparison
    "downward_short_wave_radiation_flux_surface": ("DSWRF", lambda x: x),  # both W/m²
    "downward_long_wave_radiation_flux_surface": ("DLWRF", lambda x: x),   # both W/m²
}

DYNAMICAL_VARIABLES = list(VARIABLE_MAPPINGS.keys())


# =============================================================================
# Data Loading Functions
# =============================================================================

def load_site_metadata():
    """Load site metadata from GitHub."""
    print("Loading site metadata...")
    df = pd.read_csv(SITE_METADATA_URL)
    ds = df.set_index('site_id').to_xarray()
    print(f"  Loaded {len(df)} sites")
    return ds, df


def load_dynamical_forecast(init_time, site_metadata, variables, max_lead_hours=72):
    """Load data from dynamical.org GEFS forecast dataset."""
    print(f"\nLoading dynamical.org forecast data (init_time={init_time}, lead up to {max_lead_hours}h)...")

    try:
        ds = xr.open_zarr(DYNAMICAL_FORECAST_URL, chunks='auto', decode_timedelta=True)
        print(f"  Init time range: {ds.init_time.values[0]} to {ds.init_time.values[-1]}")
        print(f"  Ensemble members: {len(ds.ensemble_member)} (0-{ds.ensemble_member.values[-1]})")

        available_vars = [v for v in variables if v in ds.data_vars]
        missing_vars = [v for v in variables if v not in ds.data_vars]
        if missing_vars:
            print(f"  Warning: Missing variables: {missing_vars}")

        subset = (
            ds[available_vars]
            .sel(init_time=init_time, method='nearest')
            .sel(lead_time=slice("0h", f"{max_lead_hours}h"))
        )

        # Select nearest grid cells but keep the matched coords for diagnostics
        subset = subset.sel(
            latitude=site_metadata.latitude,
            longitude=site_metadata.longitude,
            method='nearest'
        )

        # Report matched grid cells vs requested
        print("  Grid cell matching (requested -> matched):")
        for sid in site_metadata.site_id.values:
            req_lat = float(site_metadata.latitude.sel(site_id=sid))
            req_lon = float(site_metadata.longitude.sel(site_id=sid))
            match_lat = float(subset.latitude.sel(site_id=sid))
            match_lon = float(subset.longitude.sel(site_id=sid))
            print(f"    {sid}: ({req_lat:.4f}, {req_lon:.4f}) -> ({match_lat:.4f}, {match_lon:.4f})")

        subset = subset.drop_vars(['latitude', 'longitude'])
        subset = subset.compute()
        actual_init = pd.Timestamp(subset.init_time.values)
        print(f"  Matched init_time: {actual_init}")
        print(f"  Loaded {len(available_vars)} variables, {len(subset.lead_time)} lead times, {len(subset.ensemble_member)} ensembles")

        return subset, available_vars

    except Exception as e:
        print(f"  Error loading dynamical forecast: {e}")
        import traceback
        traceback.print_exc()
        return None, []


def load_dynamical_analysis(start_time, end_time, site_metadata, variables):
    """Load data from dynamical.org GEFS analysis dataset."""
    print(f"\nLoading dynamical.org analysis data ({start_time} to {end_time})...")

    try:
        ds = xr.open_zarr(DYNAMICAL_ANALYSIS_URL, chunks=None, decode_timedelta=True)
        print(f"  Time range: {ds.time.values[0]} to {ds.time.values[-1]}")

        available_vars = [v for v in variables if v in ds.data_vars]
        missing_vars = [v for v in variables if v not in ds.data_vars]
        if missing_vars:
            print(f"  Warning: Missing variables: {missing_vars}")

        subset = (
            ds[available_vars]
            .sel(time=slice(start_time, end_time))
        )

        subset = subset.sel(
            latitude=site_metadata.latitude,
            longitude=site_metadata.longitude,
            method='nearest'
        )

        # Report matched grid cells
        print("  Grid cell matching (requested -> matched):")
        for sid in site_metadata.site_id.values:
            req_lat = float(site_metadata.latitude.sel(site_id=sid))
            req_lon = float(site_metadata.longitude.sel(site_id=sid))
            match_lat = float(subset.latitude.sel(site_id=sid))
            match_lon = float(subset.longitude.sel(site_id=sid))
            print(f"    {sid}: ({req_lat:.4f}, {req_lon:.4f}) -> ({match_lat:.4f}, {match_lon:.4f})")

        subset = subset.drop_vars(['latitude', 'longitude'])
        subset = subset.compute()
        print(f"  Loaded {len(available_vars)} variables, {len(subset.time)} timesteps")

        return subset, available_vars

    except Exception as e:
        print(f"  Error loading dynamical analysis: {e}")
        import traceback
        traceback.print_exc()
        return None, []


def load_current_stage1(reference_date, site_ids=None):
    """Load current Stage 1 data from S3 for a given reference_datetime."""
    print(f"\nLoading current Stage 1 data (reference_datetime={reference_date})...")

    try:
        import pyarrow.dataset as pads
        import pyarrow.fs as pafs
        import os

        # Must disable EC2 metadata lookup for anonymous access to work
        old_meta = os.environ.get("AWS_EC2_METADATA_DISABLED")
        os.environ["AWS_EC2_METADATA_DISABLED"] = "TRUE"

        s3 = pafs.S3FileSystem(
            endpoint_override=CURRENT_S3_ENDPOINT,
            anonymous=True
        )
        path = f"{CURRENT_S3_BUCKET}/stage1/reference_datetime={reference_date}"

        dataset = pads.dataset(
            path, filesystem=s3, format='parquet',
            partitioning=pads.partitioning(flavor='hive')
        )
        table = dataset.to_table()
        df = table.to_pandas()

        # Restore env
        if old_meta is not None:
            os.environ["AWS_EC2_METADATA_DISABLED"] = old_meta
        else:
            os.environ.pop("AWS_EC2_METADATA_DISABLED", None)

        print(f"  Columns: {df.columns.tolist()}")

        if site_ids is not None and 'site_id' in df.columns:
            df = df[df['site_id'].isin(site_ids)]

        print(f"  Loaded {len(df)} rows")
        print(f"  Variables: {sorted(df['variable'].unique().tolist())}")
        if 'site_id' in df.columns:
            print(f"  Sites: {sorted(df['site_id'].unique().tolist())}")
        if 'ensemble' in df.columns:
            print(f"  Ensembles: {sorted(df['ensemble'].unique())[:5]}... ({df['ensemble'].nunique()} total)")

        return df

    except Exception as e:
        print(f"  Error loading current stage1: {e}")
        import traceback
        traceback.print_exc()
        return None


# =============================================================================
# Comparison Functions
# =============================================================================

def compare_forecast_vs_stage1(dyn_forecast_ds, stage1_df, site_id, variable_mappings):
    """
    Compare dynamical.org forecast vs current Stage 1 data.

    Both are raw GEFS forecasts at native temporal resolution with ensemble members.
    This is the most direct apples-to-apples comparison.
    """
    print(f"\n{'='*60}")
    print(f"FORECAST vs STAGE 1: site {site_id}")
    print(f"{'='*60}")

    if dyn_forecast_ds is None or stage1_df is None:
        print("  Cannot compare - data not loaded")
        return {}

    # Get the init_time from dynamical forecast
    init_time = pd.Timestamp(dyn_forecast_ds.init_time.values)

    # Filter stage1 to this site
    site_stage1 = stage1_df[stage1_df['site_id'] == site_id].copy()
    if len(site_stage1) == 0:
        print(f"  No Stage 1 data for {site_id}")
        return {}

    # Build a mapping from ensemble string names to integer indices
    # Stage 1 uses: gec00 (control=0), gep01-gep30 (perturbations=1-30)
    def ensemble_to_int(ens_str):
        if ens_str == 'gec00':
            return 0
        elif ens_str.startswith('gep'):
            return int(ens_str[3:])
        return -1

    site_stage1['ensemble_int'] = site_stage1['ensemble'].apply(ensemble_to_int)

    results = {}

    for dyn_var, (grib_var, transform) in variable_mappings.items():
        if transform is None:
            # Skip variables where units aren't directly comparable (e.g., precip rate vs accumulated)
            print(f"  -- {dyn_var} -> {grib_var}: Skipped (different units: rate vs accumulated)")
            continue

        if dyn_var not in dyn_forecast_ds.data_vars:
            continue

        # Get dynamical forecast values for this site
        try:
            dyn_site = dyn_forecast_ds[dyn_var].sel(site_id=site_id)
        except Exception as e:
            print(f"  {dyn_var}: Error selecting site - {e}")
            continue

        # Compute valid times from init_time + lead_time
        lead_times = dyn_site.lead_time.values  # timedelta64 array
        valid_times = init_time + lead_times

        # Get stage1 data for this variable
        var_stage1 = site_stage1[site_stage1['variable'] == grib_var].copy()
        if len(var_stage1) == 0:
            print(f"  {dyn_var} -> {grib_var}: No Stage 1 data for this variable")
            continue

        var_stage1['datetime'] = pd.to_datetime(var_stage1['datetime'], utc=True)

        # Compare per-ensemble-member at matching timestamps
        diffs_all = []
        n_comparisons = 0

        for ens_idx in dyn_site.ensemble_member.values:
            dyn_ens = dyn_site.sel(ensemble_member=ens_idx).values
            dyn_ens_transformed = transform(dyn_ens)

            # Make a series indexed by valid time
            dyn_series = pd.Series(dyn_ens_transformed, index=pd.DatetimeIndex(valid_times, tz='UTC'))

            # Get stage1 data for this ensemble member
            ens_stage1 = var_stage1[var_stage1['ensemble_int'] == ens_idx]
            if len(ens_stage1) == 0:
                continue

            cur_series = ens_stage1.set_index('datetime')['prediction']

            # Find overlapping times
            common_times = dyn_series.index.intersection(cur_series.index)
            if len(common_times) == 0:
                continue

            dyn_vals = dyn_series.loc[common_times].values
            cur_vals = cur_series.loc[common_times].values

            diffs_all.extend(dyn_vals - cur_vals)
            n_comparisons += len(common_times)

        if n_comparisons == 0:
            print(f"  {dyn_var} -> {grib_var}: No overlapping times found")
            continue

        diffs_arr = np.array(diffs_all)
        mean_diff = np.nanmean(diffs_arr)
        std_diff = np.nanstd(diffs_arr)
        max_diff = np.nanmax(np.abs(diffs_arr))
        median_diff = np.nanmedian(diffs_arr)

        results[dyn_var] = {
            'grib_var': grib_var,
            'n_comparisons': n_comparisons,
            'mean_diff': mean_diff,
            'median_diff': median_diff,
            'std_diff': std_diff,
            'max_diff': max_diff,
        }

        # Flag: for same GEFS data, differences should be very small (grid cell rounding only)
        status = "✓" if max_diff < 1.0 else "⚠"
        print(f"  {status} {dyn_var} -> {grib_var}:")
        print(f"      N={n_comparisons}, mean_diff={mean_diff:.4f}, median_diff={median_diff:.4f}")
        print(f"      std_diff={std_diff:.4f}, max_diff={max_diff:.4f}")

    return results


def compare_analysis_vs_stage1(dyn_analysis_ds, stage1_df, site_id, reference_date, variable_mappings):
    """
    Compare dynamical.org analysis vs current Stage 1 ensemble mean.

    Analysis is a single realization (closest to GEFS control run).
    Stage 1 has 31 ensemble members. Compare analysis against ensemble mean
    at matching 3-hourly timestamps.
    """
    print(f"\n{'='*60}")
    print(f"ANALYSIS vs STAGE 1 (ensemble mean): site {site_id}")
    print(f"{'='*60}")

    if dyn_analysis_ds is None or stage1_df is None:
        print("  Cannot compare - data not loaded")
        return {}

    site_stage1 = stage1_df[stage1_df['site_id'] == site_id].copy()
    if len(site_stage1) == 0:
        print(f"  No Stage 1 data for {site_id}")
        return {}

    results = {}

    for dyn_var, (grib_var, transform) in variable_mappings.items():
        if transform is None:
            print(f"  -- {dyn_var} -> {grib_var}: Skipped (different units)")
            continue

        if dyn_var not in dyn_analysis_ds.data_vars:
            continue

        try:
            dyn_site = dyn_analysis_ds[dyn_var].sel(site_id=site_id)
        except Exception as e:
            print(f"  {dyn_var}: Error - {e}")
            continue

        dyn_times = pd.to_datetime(dyn_site.time.values, utc=True)
        dyn_values = transform(dyn_site.values)
        dyn_series = pd.Series(dyn_values, index=dyn_times)

        # Get stage1 data for this variable, ensemble mean
        var_stage1 = site_stage1[site_stage1['variable'] == grib_var].copy()
        if len(var_stage1) == 0:
            print(f"  {dyn_var} -> {grib_var}: No Stage 1 data")
            continue

        var_stage1['datetime'] = pd.to_datetime(var_stage1['datetime'], utc=True)
        ens_mean = var_stage1.groupby('datetime')['prediction'].mean()

        common_times = dyn_series.index.intersection(ens_mean.index)
        if len(common_times) == 0:
            print(f"  {dyn_var} -> {grib_var}: No overlapping times")
            continue

        dyn_common = dyn_series.loc[common_times].values
        cur_common = ens_mean.loc[common_times].values

        diff = dyn_common - cur_common
        mean_diff = np.nanmean(diff)
        std_diff = np.nanstd(diff)
        max_diff = np.nanmax(np.abs(diff))
        valid = ~np.isnan(diff)
        corr = np.corrcoef(dyn_common[valid], cur_common[valid])[0, 1] if valid.sum() > 1 else np.nan

        results[dyn_var] = {
            'grib_var': grib_var,
            'n_common': len(common_times),
            'mean_diff': mean_diff,
            'std_diff': std_diff,
            'max_diff': max_diff,
            'correlation': corr,
            'dyn_mean': np.nanmean(dyn_common),
            'cur_mean': np.nanmean(cur_common),
        }

        status = "✓" if max_diff < 2.0 and corr > 0.95 else "⚠"
        print(f"  {status} {dyn_var} -> {grib_var}:")
        print(f"      N={len(common_times)}, mean_diff={mean_diff:.4f}, max_diff={max_diff:.4f}, corr={corr:.4f}")
        print(f"      dynamical_mean={np.nanmean(dyn_common):.2f}, stage1_mean={np.nanmean(cur_common):.2f}")

    return results


# =============================================================================
# Main Validation
# =============================================================================

def run_validation():
    """Run the full validation suite."""
    print("=" * 70)
    print("PHASE 1 VALIDATION: dynamical.org GEFS vs Current GEFS Pipeline")
    print("Both sources are GEFS model output — differences should be small.")
    print("=" * 70)

    # Load site metadata
    site_metadata_ds, site_metadata_df = load_site_metadata()

    test_sites = site_metadata_df['site_id'].head(3).tolist()
    print(f"\nTest sites: {test_sites}")

    # Use a date where stage1 data is known to exist on S3
    # Go back further to avoid issues with recent data availability
    reference_date = (datetime.now() - timedelta(days=200)).strftime('%Y-%m-%d')
    print(f"Reference date: {reference_date}")

    # =========================================================================
    # Load data
    # =========================================================================

    # Load current Stage 1 data
    stage1_df = load_current_stage1(reference_date, site_ids=test_sites)

    # Subset site_metadata to test sites only (faster downloads from dynamical)
    test_site_metadata = site_metadata_ds.sel(site_id=test_sites)

    # Load dynamical forecast for same init time
    init_time = np.datetime64(reference_date + "T00:00:00")
    dyn_forecast, forecast_vars = load_dynamical_forecast(
        init_time=init_time,
        site_metadata=test_site_metadata,
        variables=DYNAMICAL_VARIABLES,
        max_lead_hours=72  # 3 days — enough for validation without huge download
    )

    # Load dynamical analysis for the forecast valid time window
    analysis_start = np.datetime64(reference_date)
    analysis_end = analysis_start + np.timedelta64(3, 'D')
    dyn_analysis, analysis_vars = load_dynamical_analysis(
        start_time=analysis_start,
        end_time=analysis_end,
        site_metadata=test_site_metadata,
        variables=DYNAMICAL_VARIABLES
    )

    # =========================================================================
    # TEST 1: Dynamical Forecast vs Stage 1 (apples-to-apples)
    # =========================================================================
    print("\n" + "=" * 70)
    print("TEST 1: Dynamical Forecast vs Current Stage 1")
    print("Both are raw GEFS forecasts — comparing per-ensemble-member values")
    print("=" * 70)

    forecast_results = {}
    for site_id in test_sites:
        results = compare_forecast_vs_stage1(
            dyn_forecast, stage1_df, site_id, VARIABLE_MAPPINGS
        )
        forecast_results[site_id] = results

    # =========================================================================
    # TEST 2: Dynamical Analysis vs Stage 1 (ensemble mean)
    # =========================================================================
    print("\n" + "=" * 70)
    print("TEST 2: Dynamical Analysis vs Current Stage 1 (ensemble mean)")
    print("Analysis is single realization; Stage 1 has 31 members.")
    print("Larger differences expected due to ensemble spread.")
    print("=" * 70)

    analysis_results = {}
    for site_id in test_sites:
        results = compare_analysis_vs_stage1(
            dyn_analysis, stage1_df, site_id, reference_date, VARIABLE_MAPPINGS
        )
        analysis_results[site_id] = results

    # =========================================================================
    # Summary
    # =========================================================================
    print("\n" + "=" * 70)
    print("VALIDATION SUMMARY")
    print("=" * 70)

    if dyn_forecast is not None:
        print("✓ Connected to dynamical.org forecast dataset")
    else:
        print("✗ Failed to connect to dynamical.org forecast dataset")

    if dyn_analysis is not None:
        print("✓ Connected to dynamical.org analysis dataset")
    else:
        print("✗ Failed to connect to dynamical.org analysis dataset")

    if stage1_df is not None:
        print(f"✓ Loaded Stage 1 data ({len(stage1_df)} rows)")
    else:
        print("✗ Failed to load Stage 1 data")

    # Summarize forecast vs stage1 (the key comparison)
    if forecast_results:
        print(f"\nTEST 1 (Forecast vs Stage 1) — {len(forecast_results)} sites:")
        close_count = 0
        total_count = 0
        for site_id, site_results in forecast_results.items():
            for dyn_var, r in site_results.items():
                total_count += 1
                if r['max_diff'] < 1.0:
                    close_count += 1
                    status = "✓"
                else:
                    status = "⚠"
                print(f"  {status} {site_id} | {dyn_var}: max_diff={r['max_diff']:.4f}")

        if total_count > 0:
            print(f"\n  {close_count}/{total_count} comparisons have max_diff < 1.0")
            if close_count == total_count:
                print("  --> Data sources are consistent. Safe to proceed with migration.")
            else:
                print("  --> Some variables differ. Investigate grid cell selection or variable definitions.")

    if analysis_results:
        print(f"\nTEST 2 (Analysis vs Stage 1 ens. mean) — {len(analysis_results)} sites:")
        for site_id, site_results in analysis_results.items():
            for dyn_var, r in site_results.items():
                status = "✓" if r.get('correlation', 0) > 0.95 else "⚠"
                print(f"  {status} {site_id} | {dyn_var}: corr={r.get('correlation', float('nan')):.4f}, max_diff={r['max_diff']:.4f}")

    print("\n" + "=" * 70)
    print("Validation complete.")
    print("=" * 70)

    return {'forecast_vs_stage1': forecast_results, 'analysis_vs_stage1': analysis_results}


if __name__ == "__main__":
    run_validation()
