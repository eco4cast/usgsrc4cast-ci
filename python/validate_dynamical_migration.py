"""
Phase 1 Validation Script: Compare dynamical.org data vs current GEFS pipeline

This script pulls sample data from both sources and compares them to validate
that the dynamical.org migration will produce compatible results.

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

# Suppress some xarray warnings
warnings.filterwarnings('ignore', category=FutureWarning)


# =============================================================================
# Configuration
# =============================================================================

DYNAMICAL_ANALYSIS_URL = "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=jzwart@usgs.gov"
DYNAMICAL_FORECAST_URL = "https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=jzwart@usgs.gov"

CURRENT_S3_ENDPOINT = "https://sdsc.osn.xsede.org"
CURRENT_S3_BUCKET = "bio230014-bucket01/challenges/drivers/usgsrc4cast/noaa/gefs-v12"

# Site metadata
SITE_METADATA_URL = "https://raw.githubusercontent.com/eco4cast/usgsrc4cast-ci/main/USGS_site_metadata.csv"

# Variable mappings: dynamical name -> (CF name, transformation)
VARIABLE_MAPPINGS = {
    "temperature_2m": ("air_temperature", lambda x: x + 273.15),  # °C -> K
    "pressure_surface": ("air_pressure", lambda x: x),  # Pa -> Pa
    "relative_humidity_2m": ("relative_humidity", lambda x: x / 100),  # % -> fraction
    "wind_u_10m": ("northward_wind", lambda x: x),  # m/s -> m/s
    "wind_v_10m": ("eastward_wind", lambda x: x),  # m/s -> m/s
    "precipitation_surface": ("precipitation_flux", lambda x: x / 1000),  # mm/s -> kg/m²/s
    "downward_short_wave_radiation_flux_surface": ("surface_downwelling_shortwave_flux_in_air", lambda x: x),
    "downward_long_wave_radiation_flux_surface": ("surface_downwelling_longwave_flux_in_air", lambda x: x),
}

# Variables to compare
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


def load_dynamical_analysis(start_time, end_time, site_metadata, variables):
    """Load data from dynamical.org GEFS analysis dataset."""
    print(f"\nLoading dynamical.org analysis data ({start_time} to {end_time})...")

    try:
        ds = xr.open_zarr(DYNAMICAL_ANALYSIS_URL, chunks=None, decode_timedelta=True)
        print(f"  Available variables: {list(ds.data_vars)[:10]}...")
        print(f"  Time range: {ds.time.values[0]} to {ds.time.values[-1]}")

        # Filter to available variables
        available_vars = [v for v in variables if v in ds.data_vars]
        missing_vars = [v for v in variables if v not in ds.data_vars]
        if missing_vars:
            print(f"  Warning: Missing variables: {missing_vars}")

        # Subset by time and variables
        subset = (
            ds[available_vars]
            .sel(time=slice(start_time, end_time))
        )

        # Subset by location (nearest neighbor to sites)
        subset = subset.sel(
            latitude=site_metadata.latitude,
            longitude=site_metadata.longitude,
            method='nearest'
        ).drop_vars(['latitude', 'longitude'])

        # Load into memory
        subset = subset.compute()
        print(f"  Loaded {len(available_vars)} variables, {len(subset.time)} timesteps")

        return subset, available_vars

    except Exception as e:
        print(f"  Error loading dynamical analysis: {e}")
        return None, []


def load_dynamical_forecast(init_time, site_metadata, variables, max_lead_hours=72):
    """Load data from dynamical.org GEFS forecast dataset."""
    print(f"\nLoading dynamical.org forecast data (init_time={init_time}, lead_time up to {max_lead_hours}h)...")

    try:
        ds = xr.open_zarr(DYNAMICAL_FORECAST_URL, chunks='auto', decode_timedelta=True)
        print(f"  Available variables: {list(ds.data_vars)[:10]}...")
        print(f"  Init time range: {ds.init_time.values[0]} to {ds.init_time.values[-1]}")
        print(f"  Ensemble members: {ds.ensemble_member.values}")

        # Filter to available variables
        available_vars = [v for v in variables if v in ds.data_vars]

        # Subset by init_time, lead_time, and variables
        lead_time_max = f"{max_lead_hours}h"
        subset = (
            ds[available_vars]
            .sel(init_time=init_time, method='nearest')
            .sel(lead_time=slice("0h", lead_time_max))
        )

        # Subset by location
        subset = subset.sel(
            latitude=site_metadata.latitude,
            longitude=site_metadata.longitude,
            method='nearest'
        ).drop_vars(['latitude', 'longitude'])

        # Load into memory
        subset = subset.compute()
        print(f"  Loaded {len(available_vars)} variables, {len(subset.lead_time)} lead times, {len(subset.ensemble_member)} ensembles")

        return subset, available_vars

    except Exception as e:
        print(f"  Error loading dynamical forecast: {e}")
        return None, []


def load_current_stage3(site_id, start_date, end_date):
    """Load current Stage 3 data from S3 for comparison."""
    print(f"\nLoading current Stage 3 data for {site_id} ({start_date} to {end_date})...")

    try:
        import pyarrow.parquet as pq
        import s3fs

        # Set up S3 filesystem
        fs = s3fs.S3FileSystem(
            anon=True,
            client_kwargs={'endpoint_url': CURRENT_S3_ENDPOINT}
        )

        # Read from stage3
        path = f"{CURRENT_S3_BUCKET}/stage3/site_id={site_id}"

        # Check if path exists
        if not fs.exists(path):
            print(f"  Path not found: {path}")
            return None

        # Parse bounds as tz-aware UTC; make end exclusive (include whole end_date)
        start = pd.to_datetime(start_date, utc=True)
        end = pd.to_datetime(end_date, utc=True)
        end_exclusive = end + pd.Timedelta(days=1)

        # Read parquet files
        df = pq.read_table(
            path,
            filesystem=fs,
            filters=[
                ('datetime', '>=', start),
                ('datetime', '<=', end_exclusive)
            ]
        ).to_pandas()

        print(f"  Loaded {len(df)} rows")
        print(f"  Variables: {df['variable'].unique().tolist()}")
        print(f"  Parameters (ensembles): {sorted(df['parameter'].unique())}")

        return df

    except Exception as e:
        print(f"  Error loading current stage3: {e}")
        import traceback
        traceback.print_exc()
        return None


# =============================================================================
# Comparison Functions
# =============================================================================

def compare_analysis_values(dynamical_ds, current_df, site_id, variable_mappings):
    """Compare dynamical analysis values to current stage3 values."""
    print(f"\n{'='*60}")
    print(f"Comparing values for site {site_id}")
    print(f"{'='*60}")

    if dynamical_ds is None or current_df is None:
        print("  Cannot compare - data not loaded")
        return {}

    results = {}

    for dyn_var, (cf_var, transform) in variable_mappings.items():
        if dyn_var not in dynamical_ds.data_vars:
            continue

        # Get dynamical values for this site
        try:
            dyn_values = dynamical_ds[dyn_var].sel(site_id=site_id).values
            dyn_times = pd.to_datetime(dynamical_ds.time.values, utc=True).floor('H')
        except Exception as e:
            print(f"  {dyn_var}: Error getting dynamical values - {e}")
            continue

        # Transform dynamical values to match current pipeline
        dyn_values_transformed = transform(dyn_values)

        dyn_series = pd.Series(dyn_values_transformed, index=dyn_times) 

        # Get current values for this variable (ensemble mean for comparison)
        current_var = current_df[current_df['variable'] == cf_var].copy()
        if len(current_var) == 0:
            print(f"  {dyn_var} -> {cf_var}: No matching current data")
            continue

        current_var['datetime'] = pd.to_datetime(current_var['datetime'], utc=True).dt.floor('H')

        # Get ensemble mean
        current_mean = current_var.groupby('datetime')['prediction'].mean()

        # Find overlapping times
        # common_times = dyn_times[dyn_times.isin(current_mean.index)]
        common_times = current_mean.index.intersection(dyn_series.index)
        if len(common_times) == 0:
            print(f"  {dyn_var} -> {cf_var}: No overlapping times")
            continue

        # Get values at common times
        # dyn_common = dyn_values_transformed[dyn_times.isin(common_times)]
        dyn_common = dyn_series.loc[common_times].values
        cur_common = current_mean.loc[common_times].values

        # Calculate statistics
        diff = dyn_common - cur_common
        mean_diff = np.nanmean(diff)
        std_diff = np.nanstd(diff)
        max_diff = np.nanmax(np.abs(diff))
        corr = np.corrcoef(dyn_common[~np.isnan(diff)], cur_common[~np.isnan(diff)])[0, 1] if len(diff[~np.isnan(diff)]) > 1 else np.nan

        results[dyn_var] = {
            'cf_var': cf_var,
            'n_common': len(common_times),
            'mean_diff': mean_diff,
            'std_diff': std_diff,
            'max_diff': max_diff,
            'correlation': corr,
            'dyn_mean': np.nanmean(dyn_common),
            'cur_mean': np.nanmean(cur_common),
        }

        status = "✓" if abs(mean_diff) < 1.0 and corr > 0.9 else "⚠"
        print(f"  {status} {dyn_var} -> {cf_var}:")
        print(f"      N={len(common_times)}, mean_diff={mean_diff:.4f}, corr={corr:.4f}")
        print(f"      dynamical_mean={np.nanmean(dyn_common):.2f}, current_mean={np.nanmean(cur_common):.2f}")

    return results


# =============================================================================
# Main Validation
# =============================================================================

def run_validation():
    """Run the full validation suite."""
    print("="*70)
    print("PHASE 1 VALIDATION: dynamical.org vs Current GEFS Pipeline")
    print("="*70)

    # Load site metadata
    site_metadata_ds, site_metadata_df = load_site_metadata()

    # Select a few sites for testing
    test_sites = site_metadata_df['site_id'].head(3).tolist()
    print(f"\nTest sites: {test_sites}")

    # Define test date range (recent data)
    end_date = datetime.now() - timedelta(days=200)
    start_date = end_date - timedelta(days=3)

    print(f"Test date range: {start_date.date()} to {end_date.date()}")

    # Test 1: Dynamical Analysis Dataset
    print("\n" + "="*70)
    print("TEST 1: Dynamical Analysis Dataset (for pseudo/stage3)")
    print("="*70)

    dyn_analysis, available_vars = load_dynamical_analysis(
        start_time=np.datetime64(start_date),
        end_time=np.datetime64(end_date),
        site_metadata=site_metadata_ds,
        variables=DYNAMICAL_VARIABLES
    )

    if dyn_analysis is not None:
        print("\nDynamical Analysis Dataset Info:")
        print(f"  Dimensions: {dict(dyn_analysis.dims)}")
        print(f"  Variables loaded: {available_vars}")

        # Sample values
        for var in available_vars[:3]:
            vals = dyn_analysis[var].values.flatten()
            print(f"  {var}: min={np.nanmin(vals):.2f}, max={np.nanmax(vals):.2f}, mean={np.nanmean(vals):.2f}")

    # Test 2: Dynamical Forecast Dataset
    print("\n" + "="*70)
    print("TEST 2: Dynamical Forecast Dataset (for stage2)")
    print("="*70)

    init_time = np.datetime64(start_date.replace(hour=0, minute=0, second=0))
    dyn_forecast, forecast_vars = load_dynamical_forecast(
        init_time=init_time,
        site_metadata=site_metadata_ds,
        variables=DYNAMICAL_VARIABLES,
        max_lead_hours=72
    )

    if dyn_forecast is not None:
        print("\nDynamical Forecast Dataset Info:")
        print(f"  Dimensions: {dict(dyn_forecast.dims)}")
        print(f"  Variables loaded: {forecast_vars}")

        # Sample values
        for var in forecast_vars[:3]:
            vals = dyn_forecast[var].values.flatten()
            print(f"  {var}: min={np.nanmin(vals):.2f}, max={np.nanmax(vals):.2f}, mean={np.nanmean(vals):.2f}")

    # Test 3: Compare with Current Stage 3
    print("\n" + "="*70)
    print("TEST 3: Compare dynamical.org with Current Stage 3")
    print("="*70)

    all_results = {}
    for site_id in test_sites:
        current_df = load_current_stage3(
            site_id=site_id,
            start_date=start_date.strftime('%Y-%m-%d'),
            end_date=end_date.strftime('%Y-%m-%d')
        )

        if dyn_analysis is not None and current_df is not None:
            results = compare_analysis_values(
                dyn_analysis, current_df, site_id, VARIABLE_MAPPINGS
            )
            all_results[site_id] = results

    # Summary
    print("\n" + "="*70)
    print("VALIDATION SUMMARY")
    print("="*70)

    if dyn_analysis is not None:
        print("✓ Successfully connected to dynamical.org analysis dataset")
    else:
        print("✗ Failed to connect to dynamical.org analysis dataset")

    if dyn_forecast is not None:
        print("✓ Successfully connected to dynamical.org forecast dataset")
    else:
        print("✗ Failed to connect to dynamical.org forecast dataset")

    if all_results:
        print(f"✓ Compared data for {len(all_results)} sites")

        # Check overall correlation
        high_corr_count = 0
        total_comparisons = 0
        for site_results in all_results.values():
            for var_result in site_results.values():
                total_comparisons += 1
                if var_result.get('correlation', 0) > 0.9:
                    high_corr_count += 1

        if total_comparisons > 0:
            pct_high_corr = 100 * high_corr_count / total_comparisons
            print(f"  {high_corr_count}/{total_comparisons} ({pct_high_corr:.0f}%) variable comparisons have correlation > 0.9")

    print("\n" + "="*70)
    print("Validation complete. Review results above for any warnings.")
    print("="*70)

    return all_results


if __name__ == "__main__":
    run_validation()
