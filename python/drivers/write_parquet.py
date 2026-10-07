"""
Write processed GEFS data to partitioned parquet files matching
the current Stage 2/3 schema, either locally or on OSN S3.

Local writes are the default (useful for development and comparison). S3 writes
to OSN require OSN_KEY/OSN_SECRET credentials, which are only available in CI
(GitHub Actions) via the eco4cast org secrets — see .github/workflows/drivers_python.yaml.
"""

import os
import pyarrow as pa
import pyarrow.parquet as pq
import pyarrow.fs as pafs
import pandas as pd


# Stage 2/3 output column order
COLUMN_ORDER = [
    "site_id", "datetime", "variable", "prediction",
    "parameter", "reference_datetime", "family"
]

# OSN object store endpoint (matches challenge_configuration.yaml `endpoint`)
OSN_ENDPOINT = "https://sdsc.osn.xsede.org"


def make_osn_filesystem():
    """
    Build an authenticated OSN S3 filesystem from OSN_KEY/OSN_SECRET env vars.

    These credentials are provided as GitHub Actions secrets in CI; writing to
    OSN is not possible from an unauthenticated local machine.

    Returns
    -------
    pyarrow.fs.S3FileSystem
    """
    key = os.environ.get("OSN_KEY")
    secret = os.environ.get("OSN_SECRET")
    if not key or not secret:
        raise RuntimeError(
            "OSN_KEY and OSN_SECRET must be set to write to OSN S3. "
            "These are provided as GitHub Actions secrets and are not available "
            "for local runs — use a local --output directory instead."
        )
    # Disable EC2 metadata lookup so credentials are taken from the args, not IMDS.
    os.environ["AWS_EC2_METADATA_DISABLED"] = "TRUE"
    return pafs.S3FileSystem(
        endpoint_override=OSN_ENDPOINT,
        access_key=key,
        secret_key=secret,
        scheme="https",
    )


def list_stage2_reference_dates(output_dir: str, filesystem=None) -> set:
    """
    List reference_datetime partition values already present under a Stage 2 root.

    Mirrors generate_stage2.R's `distinct(reference_datetime)` gap check, but by
    listing partition directories (cheap) rather than reading data. Returns an
    empty set if the root does not exist yet (first run).

    Parameters
    ----------
    output_dir : str
        Stage 2 root (local path or S3 bucket key).
    filesystem : pyarrow.fs.FileSystem or None
        None for local; otherwise an S3 filesystem.

    Returns
    -------
    set of str
        Reference dates as "YYYY-MM-DD".
    """
    fs = filesystem or pafs.LocalFileSystem()
    selector = pafs.FileSelector(output_dir, recursive=False, allow_not_found=True)
    dates = set()
    for info in fs.get_file_info(selector):
        name = info.base_name
        if name.startswith("reference_datetime="):
            dates.add(name.split("=", 1)[1])
    return dates


def read_stage3_site(output_dir: str, site_id: str, filesystem=None):
    """
    Read the existing Stage 3 partition for one site, or None if absent.

    Used to extend Stage 3 incrementally (update_stage3.R behavior): the caller
    keeps existing rows older than the newly generated window and overwrites.

    Parameters
    ----------
    output_dir : str
        Stage 3 root (local path or S3 bucket key).
    site_id : str
        Site to read.
    filesystem : pyarrow.fs.FileSystem or None

    Returns
    -------
    pandas.DataFrame or None
    """
    import pyarrow.dataset as pads

    fs = filesystem or pafs.LocalFileSystem()
    path = os.path.join(output_dir, f"site_id={site_id}")
    info = fs.get_file_info(path)
    if info.type == pafs.FileType.NotFound:
        return None
    dataset = pads.dataset(path, filesystem=fs, format="parquet")
    if not dataset.files:
        return None
    df = dataset.to_table().to_pandas()
    df["site_id"] = site_id
    return df


def _write_table(table: pa.Table, partition_dir: str, filesystem):
    """Write a single parquet part to local disk or an S3 filesystem."""
    path = os.path.join(partition_dir, "part-0.parquet")
    if filesystem is None:
        os.makedirs(partition_dir, exist_ok=True)
        pq.write_table(table, path)
    else:
        # S3 has no directories to create; pyarrow writes the key directly.
        pq.write_table(table, path, filesystem=filesystem)


def write_stage2_parquet(df: pd.DataFrame, output_dir: str, filesystem=None):
    """
    Write Stage 2 DataFrame to partitioned parquet files.

    Partition scheme: reference_datetime={date}/site_id={site}/part-0.parquet

    Parameters
    ----------
    df : pd.DataFrame
        Stage 2 data with columns matching COLUMN_ORDER.
    output_dir : str
        Root path for output. For local writes a filesystem path; for S3 writes
        a bucket-relative key (e.g.
        "bio230014-bucket01/challenges/drivers/usgsrc4cast/noaa/gefs-v12/stage2").
    filesystem : pyarrow.fs.FileSystem or None
        If None, write to the local filesystem. Otherwise write via this
        filesystem (e.g. from make_osn_filesystem()).
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

        # Drop partition columns from the data (they're in the directory structure)
        out = group.drop(columns=["reference_datetime", "site_id"])
        table = pa.Table.from_pandas(out, preserve_index=False)
        _write_table(table, partition_dir, filesystem)


# Native Stage 1 / stage1-stats file columns (site_id + reference_datetime are
# partition columns). Explicit types match the existing gefs4cast on-disk schema.
NATIVE_FILE_COLUMNS = ["ensemble", "cycle", "horizon", "datetime",
                       "variable", "prediction", "family"]
NATIVE_FILE_SCHEMA = pa.schema([
    ("ensemble", pa.string()),
    ("cycle", pa.string()),
    ("horizon", pa.duration("s")),
    ("datetime", pa.timestamp("us", tz="UTC")),
    ("variable", pa.string()),
    ("prediction", pa.float64()),
    ("family", pa.string()),
])


def write_stage1_parquet(df: pd.DataFrame, output_dir: str, filesystem=None):
    """
    Write a Stage 1 or stage1-stats DataFrame to partitioned parquet files.

    Partition scheme: reference_datetime={date}/site_id={site}/part-0.parquet,
    matching gefs4cast. Used for both stage1 (family="ensemble") and stage1-stats
    (family="spread"); they share one schema.

    Parameters
    ----------
    df : pd.DataFrame
        Long native data with the NATIVE_COLUMNS from process_to_native, plus a
        reference_datetime column (or init_time embedded in the frame).
    output_dir : str
        Output root (local path or S3 bucket key).
    filesystem : pyarrow.fs.FileSystem or None
    """
    df = df.copy()
    df["datetime"] = pd.to_datetime(df["datetime"], utc=True)
    df["horizon"] = pd.to_timedelta(df["horizon"])
    # reference_datetime partition value is the init date (YYYY-MM-DD).
    ref_dates = pd.to_datetime(df["reference_datetime"]).dt.date

    for (ref_dt, site_id), group in df.groupby([ref_dates, "site_id"]):
        partition_dir = os.path.join(
            output_dir,
            f"reference_datetime={ref_dt}",
            f"site_id={site_id}",
        )
        out = group[NATIVE_FILE_COLUMNS]
        table = pa.Table.from_pandas(out, schema=NATIVE_FILE_SCHEMA,
                                     preserve_index=False)
        _write_table(table, partition_dir, filesystem)


def write_stage3_parquet(df: pd.DataFrame, output_dir: str, filesystem=None):
    """
    Write Stage 3 DataFrame to partitioned parquet files.

    Partition scheme: site_id={site}/part-0.parquet

    Parameters
    ----------
    df : pd.DataFrame
        Stage 3 data with columns matching COLUMN_ORDER.
    output_dir : str
        Root path for output. For local writes a filesystem path; for S3 writes
        a bucket-relative key (e.g.
        "bio230014-bucket01/challenges/drivers/usgsrc4cast/noaa/gefs-v12/stage3").
    filesystem : pyarrow.fs.FileSystem or None
        If None, write to the local filesystem. Otherwise write via this
        filesystem (e.g. from make_osn_filesystem()).
    """
    df = df[COLUMN_ORDER].copy()
    df["datetime"] = pd.to_datetime(df["datetime"])
    df["parameter"] = df["parameter"].astype(int)

    # Sort by variable, datetime, parameter (matches R update_stage3.R behavior)
    df = df.sort_values(["variable", "datetime", "parameter"])

    for site_id, group in df.groupby("site_id"):
        partition_dir = os.path.join(output_dir, f"site_id={site_id}")

        out = group.drop(columns=["site_id"])
        table = pa.Table.from_pandas(out, preserve_index=False)
        _write_table(table, partition_dir, filesystem)
