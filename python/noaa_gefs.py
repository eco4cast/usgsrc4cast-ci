#' NOAA GEFS tables
#'
#' Access NOAA Global Ensemble Forecast System (GEFS) forecast predictions
#' at ecological forecast sites. The GEFS is NOAA's longest horizon forecast, extending up
#' to 30 days at present, issued at 0.5 degree spatial resolution.
#' EFI downsamples these forecasts at the coordinates of all NEON sites and
#' provides efficient access to archives of these forecasts in a simple tabular
#' format for a subset of variables of interest.
#'
#' WARNING: This combined dataset contains billions of rows. Filtering
#' to a forecast issued on specific `start_date`s or other subsets before
#' `collect()`ing data into R is essential. Be patient, especially on slow
#' network connections, and handle this data with care. See examples.
#'
#' At each site, 31 ensemble member forecasts are provided
#' at 3 hr intervals for the first 10 days, and 6 hr intervals for up to 30 days
#' (840 hr) horizon. Forecasts include the following variables:
#' - TMP - temperature (K)
#' - RH - Relative humidity (%)
#' - PRES - Atmospheric pressure (Pa)
#' - UGRD - U-component of wind speed (m/s)
#' - VGRD - V-component of wind speed (m/s)
#' - APCP - Total precipitation in interval (kg/m^2)
#' - DSWRF - Downward shortwave radiation flux in interval
#' - DLWRF - Downward longwave radiation flux in interval
#'
#' GEFS forecasts are issued four times a day, as indicated by the `start_date`
#' and `cycle`. Only forecasts at midnight, `cycle = "00"` extend for the full
#' 840 hour horizon. Other cycles 06, 12, 18 are provided only 6hrs ahead,
#' as mostly being of interest for short-term forecasts. (Though users should
#' note that other NOAA products provide more much accurate and higher
#' resolution short term forecasts than GEFS.)
#'
#' All variables are given at height 2m above ground, as indicated in height.
#' See https://www.nco.ncep.noaa.gov/pmb/products/gens/ for more details on
#' GEFS variables and intervals.

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.dataset as ds
import pyarrow.fs as fs
from pyarrow.dataset import partitioning
import os

def arrow_env_vars():
    """
    Save the current AWS environment variables and modify them for Arrow usage.
    
    Returns:
    dict: A dictionary containing the original AWS environment variables.
    """
    user_region = os.getenv("AWS_DEFAULT_REGION")
    user_meta = os.getenv("AWS_EC2_METADATA_DISABLED")
    
    os.environ.pop("AWS_DEFAULT_REGION", None)
    os.environ["AWS_EC2_METADATA_DISABLED"] = "TRUE"

    return {"user_region": user_region, "user_meta": user_meta}

def unset_arrow_vars(vars):
    """
    Restore the AWS environment variables to their original values.
    
    Parameters:
    vars (dict): A dictionary containing the original AWS environment variables.
    """
    if vars["user_region"] is not None:
        os.environ["AWS_DEFAULT_REGION"] = vars["user_region"]
    if vars["user_meta"]:
        os.environ["AWS_EC2_METADATA_DISABLED"] = vars["user_meta"]
    else:
        os.environ.pop("AWS_EC2_METADATA_DISABLED", None)


def noaa_stage1(cycle='00',
                version='v12',
                endpoint='https://sdsc.osn.xsede.org',
                verbose=True,
                project_id=None,
                start_date=None):
    """
    Fetch GEFS weather forecast data from an S3 bucket.

    All variables are given at height 2m above ground, as indicated in height.
    See https://www.nco.ncep.noaa.gov/pmb/products/gens/ for more details on GEFS variables and intervals.

    References:
    https://www.nco.ncep.noaa.gov/pmb/products/gens/

    Parameters:
    cycle (str): Hour at which forecast was made (`"00"`, `"06"`, `"12"`, or `"18"`). Only `"00"` (default) has 30 days horizon.
    version (str): GEFS forecast version. Prior versions correspond to forecasts issued before 2020-09-25 which have different ensemble number and horizon, among other changes, and are not made available here. Leave as default.
    endpoint (str): The EFI host address (leave as default).
    verbose (bool): Displays or hides messages.
    project_id (str): The forecast challenge project_id you want to pull GEFS from.
    start_date (str): Forecast start date in yyyy-mm-dd format.

    Returns:
    pyarrow.dataset: A dataset containing the GEFS weather forecast data.

    Examples:
    noaa_gefs = noaa_stage1(project_id='usgsrc4cast', start_date='2024-04-01')
    # Convert to Pandas 
    noaa_gefs_df = noaa_gefs.to_table().to_pandas()
    """
    env_vars = arrow_env_vars()
    
    if project_id is None:
        raise ValueError("project_id must be provided")
    
    if start_date is None or start_date == '':
        raise ValueError("start_date must be provided in yyyy-mm-dd format")


    bucket = f"bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage1/reference_datetime={start_date}"

    # Configure S3FileSystem with the custom endpoint
    s3 = fs.S3FileSystem(endpoint_override=endpoint)
    
    # Define the partitioning scheme
    partitioning_scheme = partitioning(flavor='hive')

    # Load the Parquet files into a PyArrow dataset
    dataset = ds.dataset(bucket, 
                         filesystem=s3, 
                         format='parquet', 
                         partitioning = partitioning_scheme)
    
    unset_arrow_vars(env_vars)

    return dataset



def noaa_stage2(cycle='00',
                version='v12',
                endpoint='https://sdsc.osn.xsede.org',
                verbose=True,
                project_id=None,
                start_date=None):
    """
    NOAA GEFS forecasts with EFI stage 2 processing.

    Stage2 processing involves the following transforms of the data:
    - Fluxes are standardized to per second rates
    - Variables are renamed to match CF conventions
    - Fluxes and states are interpolated to 1 hour intervals

    Parameters:
    cycle (str): Hour at which forecast was made (`"00"`, `"06"`, `"12"`, or `"18"`). Only `"00"` (default) has 30 days horizon.
    version (str): GEFS forecast version. Prior versions correspond to forecasts issued before 2020-09-25 which have different ensemble number and horizon, among other changes, and are not made available here. Leave as default.
    endpoint (str): The EFI host address (leave as default).
    verbose (bool): Displays or hides messages.
    project_id (str): The forecast challenge project_id you want to pull GEFS from.
    start_date (str): Forecast start date in yyyy-mm-dd format.

    Returns:
    pyarrow.dataset: A dataset containing the GEFS weather forecast data with stage 2 processing.

    Examples:
    noaa_gefs_stage2 = noaa_stage2(project_id='usgsrc4cast', start_date='2024-04-01')
    noaa_gefs_stage2_df = noaa_gefs_stage2.to_table().to_pandas()
    """
    env_vars = arrow_env_vars()

    if project_id is None:
        raise ValueError("project_id must be provided")
    
    if start_date is None or start_date == '':
        raise ValueError("start_date must be provided in yyyy-mm-dd format")

    # bucket_path = f"bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage2/reference_datetime={start_date}"
    bucket_path = f"bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage2"

    # Configure S3FileSystem with the custom endpoint
    s3 = fs.S3FileSystem(endpoint_override=endpoint)
    
    # Define the partitioning scheme
    partitioning_scheme = partitioning(flavor='hive')

    # Load the Parquet files into a PyArrow dataset
    dataset = ds.dataset(bucket_path, 
                         filesystem=s3,
                         format='parquet',
                         partitioning=partitioning_scheme)
    
    # Define the filter condition
    # Filter rows where 'reference_datetime' is equal to 'start_date'
    start_date_scalar = pa.scalar(start_date, type=pa.string())
    filter_condition = pc.equal(pc.field('reference_datetime'), start_date_scalar)
    
    filtered_dataset = dataset.filter(filter_condition) 
    
    unset_arrow_vars(env_vars)

    return filtered_dataset


def noaa_stage3(version='v12',
                endpoint='https://sdsc.osn.xsede.org',
                verbose=True,
                project_id=None):
    """
    NOAA GEFS forecasts with EFI stage 3 processing.

    Stage 3 processing presents a 'nowcast' product by combining the most
    recent predictions from each available cycle. Product uses CF variable
    names and 1 hr interval.

    Parameters:
    version (str): GEFS forecast version. Leave as default.
    endpoint (str): The EFI host address. Leave as default.
    verbose (bool): Displays or hides messages.
    project_id (str): The forecast challenge project_id you want to pull GEFS from.

    Returns:
    pyarrow.dataset.Dataset: A dataset containing the GEFS weather forecast data with stage 3 processing.

    Examples:
    noaa_gefs_stage3 = noaa_stage3(project_id='usgsrc4cast')
    noaa_gefs_stage3_df = noaa_gefs_stage3.to_table().to_pandas()
    """
    env_vars = arrow_env_vars()

    if project_id is None:
        raise ValueError("project_id must be provided")

    bucket_path = f"bio230014-bucket01/challenges/drivers/{project_id}/noaa/gefs-v12/stage3"

    # Configure S3FileSystem with the custom endpoint
    s3 = fs.S3FileSystem(endpoint_override=endpoint)
    
    # Define the partitioning scheme
    partitioning_scheme = partitioning(flavor='hive')

    # Load the Parquet files into a PyArrow dataset
    dataset = ds.dataset(bucket_path, 
                         filesystem=s3, 
                         format='parquet',
                         partitioning=partitioning_scheme)

    unset_arrow_vars(env_vars)

    return dataset
