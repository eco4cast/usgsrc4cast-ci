"""
Write processed GEFS data to partitioned parquet files matching
the current Stage 2/3 schema on S3.
"""

import os
import pyarrow as pa
import pyarrow.parquet as pq
import pandas as pd


# Stage 2/3 output column order
COLUMN_ORDER = [
    "site_id", "datetime", "variable", "prediction",
    "parameter", "reference_datetime", "family"
]


def write_stage2_parquet(df: pd.DataFrame, output_dir: str):
    """
    Write Stage 2 DataFrame to partitioned parquet files.

    Partition scheme: reference_datetime={date}/site_id={site}/part-0.parquet

    Parameters
    ----------
    df : pd.DataFrame
        Stage 2 data with columns matching COLUMN_ORDER.
    output_dir : str
        Root directory for output (e.g., "drivers/usgsrc4cast/noaa/gefs-v12/stage2").
    """
    df = df[COLUMN_ORDER].copy()
    df["reference_datetime"] = pd.to_datetime(df["reference_datetime"])
    df["datetime"] = pd.to_datetime(df["datetime"])
    df["parameter"] = df["parameter"].astype(int)

    for (ref_dt, site_id), group in df.groupby(
        [df["reference_datetime"].dt.date, "site_id"]
    ):
        ref_date_str = str(ref_dt)
        partition_dir = os.path.join(
            output_dir,
            f"reference_datetime={ref_date_str}",
            f"site_id={site_id}"
        )
        os.makedirs(partition_dir, exist_ok=True)

        # Drop partition columns from the data (they're in the directory structure)
        out = group.drop(columns=["reference_datetime", "site_id"])
        table = pa.Table.from_pandas(out, preserve_index=False)
        pq.write_table(table, os.path.join(partition_dir, "part-0.parquet"))


def write_stage3_parquet(df: pd.DataFrame, output_dir: str):
    """
    Write Stage 3 DataFrame to partitioned parquet files.

    Partition scheme: site_id={site}/part-0.parquet

    Parameters
    ----------
    df : pd.DataFrame
        Stage 3 data with columns matching COLUMN_ORDER.
    output_dir : str
        Root directory for output (e.g., "drivers/usgsrc4cast/noaa/gefs-v12/stage3").
    """
    df = df[COLUMN_ORDER].copy()
    df["datetime"] = pd.to_datetime(df["datetime"])
    df["parameter"] = df["parameter"].astype(int)

    # Sort by variable, datetime, parameter (matches R update_stage3.R behavior)
    df = df.sort_values(["variable", "datetime", "parameter"])

    for site_id, group in df.groupby("site_id"):
        partition_dir = os.path.join(output_dir, f"site_id={site_id}")
        os.makedirs(partition_dir, exist_ok=True)

        out = group.drop(columns=["site_id"])
        table = pa.Table.from_pandas(out, preserve_index=False)
        pq.write_table(table, os.path.join(partition_dir, "part-0.parquet"))
