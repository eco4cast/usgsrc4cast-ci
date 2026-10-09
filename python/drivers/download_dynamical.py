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
from drivers.process_to_native import (
    process_forecast_to_stage1,
    process_forecast_to_stage1_stats,
)
from drivers.write_parquet import (
    write_stage1_parquet,
    write_stage2_parquet,
    write_stage3_parquet,
    list_stage2_reference_dates,
    read_stage3_site,
    delete_stage3_site,
    stage3_site_summary,
    make_osn_filesystem,
)


# =============================================================================
# Configuration
# =============================================================================

SITE_METADATA_URL = "https://raw.githubusercontent.com/eco4cast/usgsrc4cast-ci/main/USGS_site_metadata.csv"

# OSN bucket roots for production Stage 2/3 drivers (used with --s3).
# Mirrors challenge_configuration.yaml `noaa_forecast_bucket`.
S3_GEFS_ROOT = "bio230014-bucket01/challenges/drivers/usgsrc4cast/noaa/gefs-v12"
S3_STAGE1_BUCKET = f"{S3_GEFS_ROOT}/stage1"
S3_STAGE1_STATS_BUCKET = f"{S3_GEFS_ROOT}/stage1-stats"
S3_STAGE2_BUCKET = f"{S3_GEFS_ROOT}/stage2"
S3_STAGE3_BUCKET = f"{S3_GEFS_ROOT}/stage3"

# Stage 2/3 use the 8 CF-mapped weather drivers.
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

# Stage 1 / stage1-stats carry the 16 GRIB variables dynamical exposes (the 9
# land-surface/flux GRIB vars gefs4cast had are not available upstream). Must
# stay in sync with process_to_native.GRIB_VARIABLE_MAP.
STAGE1_VARIABLES = [
    "temperature_2m",
    "maximum_temperature_2m",
    "minimum_temperature_2m",
    "relative_humidity_2m",
    "pressure_surface",
    "wind_u_10m",
    "wind_v_10m",
    "precipitation_surface",
    "downward_short_wave_radiation_flux_surface",
    "downward_long_wave_radiation_flux_surface",
    "total_cloud_cover_atmosphere",
    "precipitable_water_atmosphere",
    "categorical_rain_surface",
    "categorical_snow_surface",
    "categorical_freezing_rain_surface",
    "categorical_ice_pellets_surface",
]

# Default LOCAL output directories (relative to repo root). With --s3 the
# production OSN buckets S3_STAGE2_BUCKET / S3_STAGE3_BUCKET are targeted instead.
STAGE1_OUTPUT = "drivers/usgsrc4cast/noaa/gefs-v12/stage1"
STAGE1_STATS_OUTPUT = "drivers/usgsrc4cast/noaa/gefs-v12/stage1-stats"
STAGE2_OUTPUT = "drivers/usgsrc4cast/noaa/gefs-v12/stage2"
STAGE3_OUTPUT = "drivers/usgsrc4cast/noaa/gefs-v12/stage3"

# Daily stage2 gap-fill window. generate_stage2.R looks back 7 days and fills
# whichever reference_datetimes are missing from S3.
STAGE2_LOOKBACK_DAYS = 7
# Stage 3 re-processing overlap. update_stage3.R re-does the trailing 3 days when
# extending the per-site analysis record forward.
STAGE3_OVERLAP_DAYS = 3

# Stage 2/3 schema column order (shared with write_parquet).
COLUMN_ORDER = [
    "site_id", "datetime", "variable", "prediction",
    "parameter", "reference_datetime", "family",
]


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


def resolve_target(output: str, use_s3: bool, s3_bucket: str):
    """
    Return (output_dir, filesystem) for either a local or OSN S3 write.

    Local writes (filesystem=None) are the default; --s3 switches to the
    production OSN bucket, which requires OSN_KEY/OSN_SECRET (CI only).
    """
    if use_s3:
        return s3_bucket, make_osn_filesystem()
    return output, None


def _as_naive(series: pd.Series) -> pd.Series:
    """Coerce a datetime series to tz-naive UTC for safe comparison/merge."""
    s = pd.to_datetime(series)
    if getattr(s.dt, "tz", None) is not None:
        s = s.dt.tz_convert("UTC").dt.tz_localize(None)
    return s


def _date_range(start: str, end: str) -> list:
    """Inclusive list of YYYY-MM-DD date strings from start to end."""
    return [d.strftime("%Y-%m-%d") for d in pd.date_range(start, end, freq="D")]


# =============================================================================
# Stage 1: Native-resolution forecast + ensemble stats
# =============================================================================

def generate_stage1_date(reference_date: str, stage1_dir: str, stats_dir: str,
                         filesystem, lead_time: str = "35d"):
    """
    Generate + write Stage 1 and stage1-stats for a single reference date.

    Both products come from one forecast pull: Stage 1 is the per-ensemble native
    data, stage1-stats is its ensemble mean/spread.
    """
    print(f"Generating Stage 1 for reference_date={reference_date}")

    site_metadata, _, _ = load_site_metadata()
    init_time = np.datetime64(f"{reference_date}T00:00:00")

    print("  Downloading forecast from dynamical.org...")
    forecast_ds = pull_gefs_operational(
        start_time=init_time,
        end_time=init_time,
        site_metadata=site_metadata,
        lead_times=lead_time,
        variables=STAGE1_VARIABLES,
    )

    print("  Building native Stage 1 (per-ensemble)...")
    s1 = process_forecast_to_stage1(forecast_ds)
    s1["reference_datetime"] = reference_date
    print(f"  Writing Stage 1 parquet to {stage1_dir}/")
    write_stage1_parquet(s1, stage1_dir, filesystem=filesystem)

    print("  Building stage1-stats (ensemble mean/spread)...")
    stats = process_forecast_to_stage1_stats(forecast_ds)
    stats["reference_datetime"] = reference_date
    print(f"  Writing stage1-stats parquet to {stats_dir}/")
    write_stage1_parquet(stats, stats_dir, filesystem=filesystem)

    print(f"  Done: stage1={len(s1)} rows, stage1-stats={len(stats)} rows")


def run_stage1(dates: list, stage1_dir: str, stats_dir: str, filesystem,
               lead_time: str, force: bool = False):
    """
    Generate Stage 1 + stage1-stats for a list of candidate reference dates,
    skipping dates already present in Stage 1 (unless --force). Each date is
    attempted independently so one failure does not abort a backfill.
    """
    existing = set() if force else list_stage2_reference_dates(stage1_dir, filesystem)

    todo = [d for d in dates if d not in existing]
    skipped = sorted(set(dates) - set(todo))
    if skipped:
        print(f"Skipping {len(skipped)} reference_datetime(s) already present: "
              f"{skipped[0]} .. {skipped[-1]}")

    failures = []
    for d in todo:
        try:
            generate_stage1_date(d, stage1_dir, stats_dir, filesystem, lead_time)
        except Exception as exc:  # keep backfilling remaining dates
            print(f"  ERROR generating {d}: {exc}")
            failures.append(d)

    print(f"\nStage 1 complete: {len(todo) - len(failures)} generated, "
          f"{len(skipped)} skipped, {len(failures)} failed")
    if failures:
        print(f"  Failed dates: {failures}")
    return failures


# =============================================================================
# Stage 2: Forecast
# =============================================================================

def generate_stage2_date(reference_date: str, output_dir: str, filesystem,
                         lead_time: str = "35d"):
    """
    Generate + write Stage 2 data for a single reference date.

    Parameters
    ----------
    reference_date : str
        Forecast initialization date (YYYY-MM-DD).
    output_dir : str
        Output root (local path or S3 bucket key).
    filesystem : pyarrow.fs.FileSystem or None
        None for local; otherwise an OSN S3 filesystem.
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
    write_stage2_parquet(df, output_dir, filesystem=filesystem)

    n_sites = df["site_id"].nunique()
    n_hours = df["datetime"].nunique()
    print(f"  Done: {len(df)} rows, {n_sites} sites, {n_hours} hours")
    return df


def run_stage2(dates: list, output_dir: str, filesystem, lead_time: str,
               force: bool = False):
    """
    Generate Stage 2 for a list of candidate reference dates.

    Mirrors generate_stage2.R: dates already present in the output are skipped
    (unless --force). Each date is attempted independently so one unpublished or
    failed init does not abort a multi-day backfill.
    """
    existing = set() if force else list_stage2_reference_dates(output_dir, filesystem)

    todo = [d for d in dates if d not in existing]
    skipped = sorted(set(dates) - set(todo))
    if skipped:
        print(f"Skipping {len(skipped)} reference_datetime(s) already present: "
              f"{skipped[0]} .. {skipped[-1]}")

    failures = []
    for d in todo:
        try:
            generate_stage2_date(d, output_dir, filesystem, lead_time)
        except Exception as exc:  # keep backfilling remaining dates
            print(f"  ERROR generating {d}: {exc}")
            failures.append(d)

    print(f"\nStage 2 complete: {len(todo) - len(failures)} generated, "
          f"{len(skipped)} skipped, {len(failures)} failed")
    if failures:
        print(f"  Failed dates: {failures}")
    return failures


# =============================================================================
# Stage 3: Analysis (pseudo-historical)
# =============================================================================

def run_stage3(start_date, end_date: str, output_dir: str, filesystem,
               overlap_days: int = STAGE3_OVERLAP_DAYS, rebuild_sites=None):
    """
    Build / extend the fresh single-member Stage 3 analysis record.

    Fresh-history model (dynamical migration): Stage 3 is a single-member product
    derived from the deterministic GEFS analysis. The pre-migration record was a
    31-member product (~13M rows/site) derived from the pseudo forecast; it is
    never loaded (that OOMs the runner) — each per-site write overwrites it.

    Per site (processed one at a time to bound memory):
      - If a small single-member record already exists, extend it: keep rows older
        than the newly pulled window and append the new rows.
      - If the site is absent or still holds the oversized legacy record, write the
        freshly pulled single-member data (replacing any legacy file).
      - If the site is in rebuild_sites, skip the existing record entirely: delete
        the partition and write the freshly pulled window (repair for partitions
        written with a broken schema, e.g. the null-typed reference_datetime of
        the 5 DWR sites — see docs/stage3_reference_datetime_null_type_bug.md).
        For a chunked rebuild, pass --rebuild only on the first chunk; later
        chunks extend normally.

    rebuild_sites: None = no rebuild; empty list = all sites; otherwise the
    given site IDs.

    The pull window starts at --start if given, else overlap_days before the
    earliest existing single-member max datetime. When no single-member history
    exists yet (first fresh build / all-legacy), --start is required.
    """
    site_metadata, site_lats, site_lons = load_site_metadata()
    site_ids = list(site_lats.keys())
    if rebuild_sites is None:
        rebuild_sites = set()          # flag not given
    elif len(rebuild_sites) == 0:
        rebuild_sites = set(site_ids)  # bare --rebuild = all sites
    else:
        rebuild_sites = set(rebuild_sites)
    unknown = rebuild_sites - set(site_ids)
    if unknown:
        raise SystemExit(f"Unknown site_id(s) in --rebuild: {sorted(unknown)}")

    # Cheaply (metadata-only) find how far each site's existing SINGLE-MEMBER record
    # extends. Legacy 31-member records report max=None and are flagged for replace.
    site_max = {}
    legacy_sites = []
    for sid in site_ids:
        if sid in rebuild_sites:
            continue  # rebuild: ignore the existing record, write fresh
        summ = stage3_site_summary(output_dir, sid, filesystem)
        if summ is None:
            continue
        _, max_dt = summ
        if max_dt is None:
            legacy_sites.append(sid)                 # oversized legacy -> replace
        else:
            site_max[sid] = _as_naive(pd.Series([max_dt])).iloc[0]

    # Decide the analysis pull window.
    if start_date is not None:
        pull_start = pd.Timestamp(start_date)
    elif site_max:
        pull_start = min(site_max.values()).normalize() - pd.Timedelta(days=overlap_days)
    else:
        raise SystemExit(
            "Stage 3 has no single-member history to extend (sites are empty or "
            "hold the legacy 31-member record); supply --start to build the fresh "
            "single-member record."
        )
    pull_start_str = pull_start.strftime("%Y-%m-%d")

    if rebuild_sites and start_date is None:
        print("  WARNING: --rebuild without --start: rebuilt sites will only "
              "cover the pull window derived from the other sites' history, "
              "not their full record.")

    print(f"Pulling analysis {pull_start_str} .. {end_date} "
          f"(extend {len(site_max)}, replace-legacy {len(legacy_sites)}, "
          f"rebuild {len(rebuild_sites)}, {len(site_ids)} sites total)")

    analysis_ds = pull_gefs_analysis(
        start_time=np.datetime64(pull_start_str),
        end_time=np.datetime64(end_date),
        site_metadata=site_metadata,
        variables=DYNAMICAL_VARIABLES,
    )

    print("  Processing to hourly with solar geometry correction...")
    df_new = process_analysis_to_stage3(analysis_ds, site_lats, site_lons)
    df_new["datetime"] = _as_naive(df_new["datetime"])

    # Write one site at a time so no more than a single site's record is in memory.
    written = 0
    total_rows = 0
    for sid in site_ids:
        new_s = df_new[df_new["site_id"] == sid]
        if new_s.empty:
            continue
        if sid in site_max:  # extend existing small single-member record
            min_new = new_s["datetime"].min()
            old = read_stage3_site(output_dir, sid, filesystem)
            old["datetime"] = _as_naive(old["datetime"])
            old = old[old["datetime"] < min_new].reindex(columns=COLUMN_ORDER)
            out = pd.concat([old, new_s[COLUMN_ORDER]], ignore_index=True)
        else:                # fresh build, legacy replacement, or rebuild
            if sid in rebuild_sites:
                # Drop the old partition first so stale part files can't mix
                # with the fresh write.
                delete_stage3_site(output_dir, sid, filesystem)
            out = new_s[COLUMN_ORDER].copy()

        write_stage3_parquet(out, output_dir, filesystem=filesystem)
        written += 1
        total_rows += len(out)

    print(f"Stage 3 complete: wrote {written} sites, {total_rows} rows")


# =============================================================================
# CLI
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Download and process GEFS data from dynamical.org"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Stage 1 (native resolution) + stage1-stats
    s1 = subparsers.add_parser(
        "stage1", help="Generate native Stage 1 + stage1-stats forecast data")
    s1.add_argument("--date", default=None,
                    help="Single reference date (YYYY-MM-DD).")
    s1.add_argument("--start", default=None,
                    help="Backfill range start (YYYY-MM-DD). Use with --end.")
    s1.add_argument("--end", default=None,
                    help="Backfill range end (YYYY-MM-DD). Use with --start.")
    s1.add_argument("--lead-time", default="35d",
                    help="Max lead time (e.g., 35d, 10d). Default: 35d.")
    s1.add_argument("--output", default=STAGE1_OUTPUT,
                    help=f"Local Stage 1 output directory. Default: {STAGE1_OUTPUT}")
    s1.add_argument("--stats-output", default=STAGE1_STATS_OUTPUT,
                    help=f"Local stage1-stats output directory. Default: {STAGE1_STATS_OUTPUT}")
    s1.add_argument("--s3", action="store_true",
                    help="Write to the production OSN bucket (needs OSN_KEY/OSN_SECRET).")
    s1.add_argument("--force", action="store_true",
                    help="Regenerate even reference dates already present.")

    # Stage 2
    s2 = subparsers.add_parser("stage2", help="Generate Stage 2 forecast data")
    s2.add_argument("--date", default=None,
                    help="Single reference date (YYYY-MM-DD).")
    s2.add_argument("--start", default=None,
                    help="Backfill range start (YYYY-MM-DD). Use with --end.")
    s2.add_argument("--end", default=None,
                    help="Backfill range end (YYYY-MM-DD). Use with --start.")
    s2.add_argument("--lead-time", default="35d",
                    help="Max lead time (e.g., 35d, 10d). Default: 35d.")
    s2.add_argument("--output", default=STAGE2_OUTPUT,
                    help=f"Local output directory. Default: {STAGE2_OUTPUT}")
    s2.add_argument("--s3", action="store_true",
                    help="Write to the production OSN bucket (needs OSN_KEY/OSN_SECRET).")
    s2.add_argument("--force", action="store_true",
                    help="Regenerate even reference dates already present.")

    # Stage 3
    s3 = subparsers.add_parser("stage3", help="Generate/update Stage 3 analysis data")
    s3.add_argument("--start", default=None,
                    help="Start date (YYYY-MM-DD). Default: extend from existing data.")
    s3.add_argument("--end", default=None,
                    help="End date (YYYY-MM-DD). Default: yesterday.")
    s3.add_argument("--overlap-days", type=int, default=STAGE3_OVERLAP_DAYS,
                    help=f"Re-processing overlap. Default: {STAGE3_OVERLAP_DAYS}.")
    s3.add_argument("--output", default=STAGE3_OUTPUT,
                    help=f"Local output directory. Default: {STAGE3_OUTPUT}")
    s3.add_argument("--s3", action="store_true",
                    help="Write to the production OSN bucket (needs OSN_KEY/OSN_SECRET).")
    s3.add_argument("--rebuild", nargs="*", default=None, metavar="SITE_ID",
                    help="Rebuild site(s) from scratch: skip the extend path, "
                         "delete the existing partition, and write the pulled "
                         "window fresh. No site args = all sites. Use with "
                         "--start; for a chunked rebuild pass --rebuild only on "
                         "the first chunk.")

    args = parser.parse_args()

    def forecast_candidate_dates():
        """Shared stage1/stage2 date selection: backfill range, single, or window."""
        if args.start and args.end:
            return _date_range(args.start, args.end)            # one-shot backfill
        if args.date:
            return [args.date]                                  # single date
        today = datetime.now().date()                           # daily gap-fill window
        return _date_range(
            (today - timedelta(days=STAGE2_LOOKBACK_DAYS)).strftime("%Y-%m-%d"),
            (today - timedelta(days=1)).strftime("%Y-%m-%d"),
        )

    if args.command == "stage1":
        stage1_dir, filesystem = resolve_target(args.output, args.s3, S3_STAGE1_BUCKET)
        stats_dir = S3_STAGE1_STATS_BUCKET if args.s3 else args.stats_output
        run_stage1(forecast_candidate_dates(), stage1_dir, stats_dir, filesystem,
                   args.lead_time, force=args.force)

    elif args.command == "stage2":
        output_dir, filesystem = resolve_target(args.output, args.s3, S3_STAGE2_BUCKET)
        run_stage2(forecast_candidate_dates(), output_dir, filesystem,
                   args.lead_time, force=args.force)

    elif args.command == "stage3":
        output_dir, filesystem = resolve_target(args.output, args.s3, S3_STAGE3_BUCKET)
        end = args.end or (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        run_stage3(args.start, end, output_dir, filesystem,
                   overlap_days=args.overlap_days, rebuild_sites=args.rebuild)


if __name__ == "__main__":
    main()
