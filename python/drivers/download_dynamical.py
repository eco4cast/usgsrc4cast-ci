"""
Download and process GEFS data from dynamical.org for the forecasting challenge.

Replaces the R-based drivers pipeline (gefs4cast) with direct access to
dynamical.org zarr stores. Produces Stage 2 (forecast) and Stage 3
(pseudo-historical analysis) parquet files compatible with the existing
challenge infrastructure.

Usage:
    # Generate Stage 2 for today's forecast
    python -m python.drivers.download_dynamical stage2

    # Update Stage 3 with recent analysis data
    python -m python.drivers.download_dynamical stage3

    # Generate Stage 2 for a specific date
    python -m python.drivers.download_dynamical stage2 --date 2025-09-07

    # Stage 3 with custom date range
    python -m python.drivers.download_dynamical stage3 --start 2025-09-01 --end 2025-09-07
"""

import argparse
import sys
import os
import numpy as np
import pandas as pd
import xarray as xr
from datetime import datetime, timedelta

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dynamical_utils import pull_gefs_operational, pull_gefs_analysis
from drivers.process_to_hourly import (
    process_forecast_to_stage2,
    process_analysis_to_stage3,
)
from drivers.write_parquet import write_stage2_parquet, write_stage3_parquet


# =============================================================================
# Configuration
# =============================================================================

SITE_METADATA_URL = "https://raw.githubusercontent.com/eco4cast/usgsrc4cast-ci/main/USGS_site_metadata.csv"

DYNAMICAL_VARIABLES = [
    "temperature_2m",
    "pressure_surface",
    "relative_humidity_2m",
    "wind_u_10m",
    "wind_v_10m",
    "precipitation_surface",
    "downward_short_wave_radiation_flux_surface",
    "downward_long_wave_radiation_flux_surface",
]

# Default output directories (relative to repo root)
STAGE2_OUTPUT = "drivers/usgsrc4cast/noaa/gefs-v12/stage2"
STAGE3_OUTPUT = "drivers/usgsrc4cast/noaa/gefs-v12/stage3"


# =============================================================================
# Helpers
# =============================================================================

def load_site_metadata():
    """Load site metadata and return xarray Dataset plus lat/lon dicts."""
    df = pd.read_csv(SITE_METADATA_URL)
    ds = df.set_index("site_id").to_xarray()

    site_lats = dict(zip(df["site_id"], df["latitude"]))
    site_lons = dict(zip(df["site_id"], df["longitude"]))

    return ds, site_lats, site_lons


# =============================================================================
# Stage 2: Forecast
# =============================================================================

def generate_stage2(reference_date: str, output_dir: str, lead_time: str = "35d"):
    """
    Generate Stage 2 data from dynamical.org forecast for a given date.

    Parameters
    ----------
    reference_date : str
        Forecast initialization date (YYYY-MM-DD).
    output_dir : str
        Output directory for parquet files.
    lead_time : str
        Maximum lead time (e.g., "35d", "10d").
    """
    print(f"Generating Stage 2 for reference_date={reference_date}")

    site_metadata, site_lats, site_lons = load_site_metadata()

    init_time = np.datetime64(f"{reference_date}T00:00:00")

    print("  Downloading forecast from dynamical.org...")
    forecast_ds = pull_gefs_operational(
        start_time=init_time,
        end_time=init_time,
        site_metadata=site_metadata,
        lead_times=lead_time,
        variables=DYNAMICAL_VARIABLES,
    )

    # The GEFS 35-day forecast is published in stages: dynamical.org ingests the
    # 0-16 day segment first and backfills days 16-35 hours later. On a run day the
    # newest init therefore only covers ~16 leads. Warn if the requested horizon is
    # not fully covered so the operator can rerun once the extension is published.
    max_lead_days = pd.to_timedelta(forecast_ds.lead_time.values.max()).days
    requested_days = int(pd.to_timedelta(lead_time).days)
    if max_lead_days < requested_days:
        print(f"  WARNING: init {reference_date} covers only {max_lead_days}/"
              f"{requested_days} lead days (35-day extension not yet published?)")

    print("  Processing to hourly with solar geometry correction...")
    df = process_forecast_to_stage2(forecast_ds, site_lats, site_lons)

    print(f"  Writing parquet to {output_dir}/")
    write_stage2_parquet(df, output_dir)

    n_sites = df["site_id"].nunique()
    n_hours = df["datetime"].nunique()
    print(f"  Done: {len(df)} rows, {n_sites} sites, {n_hours} hours")
    return df


# =============================================================================
# Stage 3: Analysis (pseudo-historical)
# =============================================================================

def generate_stage3(start_date: str, end_date: str, output_dir: str):
    """
    Generate Stage 3 data from dynamical.org analysis.

    Parameters
    ----------
    start_date : str
        Start date (YYYY-MM-DD).
    end_date : str
        End date (YYYY-MM-DD).
    output_dir : str
        Output directory for parquet files.
    """
    print(f"Generating Stage 3 for {start_date} to {end_date}")

    site_metadata, site_lats, site_lons = load_site_metadata()

    print("  Downloading analysis from dynamical.org...")
    analysis_ds = pull_gefs_analysis(
        start_time=np.datetime64(start_date),
        end_time=np.datetime64(end_date),
        site_metadata=site_metadata,
        variables=DYNAMICAL_VARIABLES,
    )

    print("  Processing to hourly with solar geometry correction...")
    df = process_analysis_to_stage3(analysis_ds, site_lats, site_lons)

    print(f"  Writing parquet to {output_dir}/")
    write_stage3_parquet(df, output_dir)

    n_sites = df["site_id"].nunique()
    n_hours = df["datetime"].nunique()
    print(f"  Done: {len(df)} rows, {n_sites} sites, {n_hours} hours")
    return df


# =============================================================================
# CLI
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Download and process GEFS data from dynamical.org"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Stage 2
    s2 = subparsers.add_parser("stage2", help="Generate Stage 2 forecast data")
    s2.add_argument("--date", default=None,
                    help="Reference date (YYYY-MM-DD). Default: today.")
    s2.add_argument("--lead-time", default="35d",
                    help="Max lead time (e.g., 35d, 10d). Default: 35d.")
    s2.add_argument("--output", default=STAGE2_OUTPUT,
                    help=f"Output directory. Default: {STAGE2_OUTPUT}")

    # Stage 3
    s3 = subparsers.add_parser("stage3", help="Generate/update Stage 3 analysis data")
    s3.add_argument("--start", default=None,
                    help="Start date (YYYY-MM-DD). Default: 7 days ago.")
    s3.add_argument("--end", default=None,
                    help="End date (YYYY-MM-DD). Default: yesterday.")
    s3.add_argument("--output", default=STAGE3_OUTPUT,
                    help=f"Output directory. Default: {STAGE3_OUTPUT}")

    args = parser.parse_args()

    if args.command == "stage2":
        ref_date = args.date or datetime.now().strftime("%Y-%m-%d")
        generate_stage2(ref_date, args.output, args.lead_time)

    elif args.command == "stage3":
        end = args.end or (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        start = args.start or (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")
        generate_stage3(start, end, args.output)


if __name__ == "__main__":
    main()
