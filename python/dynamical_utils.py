import xarray as xr
import pandas as pd
import numpy as np
from sklearn.cluster import DBSCAN
from sklearn.metrics.pairwise import haversine_distances

def pull_gefs_analysis(
        start_time: np.datetime64,
        end_time: np.datetime64,
        site_metadata: xr.Dataset,
        variables: list,
        base_url: str = "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=",
        email: str = "optional@email.com"
) -> xr.Dataset:
    """
    Retrieves a subset of the GEFS analysis zarr store from dynamical.org.

    Parameters
    ----------
    start_time : np.datetime64
        Start date of the analysis.
    end_time : np.datetime64
        End date of the analysis.
    site_metadata : xr.Dataset
        Dataset containing 'latitude' and 'longitude' variables.
    variables : list
        List of variable names to include in the subset.
    base_url : str, optional
        Base URL of the zarr store (default: "https://data.dynamical.org/noaa/gefs/analysis/latest.zarr?email=").
    email : str, optional
        Email address to include in the URL (default: "optional@email.com").

    Returns
    -------
    xr.Dataset
        Subset of the GEFS analysis zarr store.

    Notes
    -----
    The `site_metadata` parameter should contain 'latitude' and 'longitude' columns.
    The function uses the `nearest` method to select the grid point closest to the specified location.
    """
    # Construct the full URL with the provided email
    url = base_url + email

    # Open the zarr store
    zarr = xr.open_zarr(url, chunks=None, decode_timedelta=True)  

    # First, select the time and variables to minimize data transfer
    # Then do spatial subsetting - this order is more efficient
    subset_zarr = (
        zarr[variables]
        .sel(time=slice(start_time, end_time))
    )

    # Do spatial bounding box subset
    subset_zarr = auto_spatial_subset(ds=subset_zarr, site_metadata=site_metadata)

    # Select individual points using their integer indices
    # site_metadata is an indexed / has a dimension that is used for vectorized indexing.
    #  because latitude and longitude have the same dimension name, xarray uses this
    #  dimension in the new subsetted dataset as the index instead of lat/lon
    subset_zarr = (
        subset_zarr
        .sel(latitude=site_metadata.latitude,
             longitude=site_metadata.longitude,
             method='nearest')
        .drop_vars(['latitude', 'longitude'])
    )

    return subset_zarr

def pull_gefs_operational(
        start_time: np.datetime64,
        end_time: np.datetime64,
        site_metadata: xr.Dataset,
        lead_times: int,
        variables: list,
        base_url: str = "https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=",
        email: str = "optional@email.com"
) -> xr.Dataset:
    """
    Retrieves a subset of the GEFS forecast zarr store from dynamical.org.

    Parameters
    ----------
    start_time : np.datetime64
        Start date of the forecast initiation time.
    end_time : np.datetime64
        End date of the forecast initiation time.
    site_metadata : xr.Dataset
        Dataset containing 'latitude' and 'longitude' variables.
    lead_times : int
        Number of lead times to include in the subset.
    variables : list
        List of variable names to include in the subset.
    base_url : str, optional
        Base URL of the zarr store (default: "https://data.dynamical.org/noaa/gefs/forecast-35-day/latest.zarr?email=").
    email : str, optional
        Email address to include in the URL (default: "optional@email.com").

    Returns
    -------
    xr.Dataset
        Subset of the GEFS forecast zarr store.

    Notes
    -----
    The `site_metadata` parameter should contain 'latitude' and 'longitude' columns.
    The function uses the `nearest` method to select the grid point closest to the specified location.
    The lead times are selected using the `slice` method, with the end value being the specified `lead_times`.
    """
    # Construct the full URL with the provided email
    url = base_url + email

    # Open the zarr store
    zarr = xr.open_zarr(url, chunks='auto', decode_timedelta=True)

    # First, select the time, lead_time, and variables to minimize data transfer
    # Then do spatial subsetting - this order is more efficient
    subset_zarr = (
        zarr[variables]
        .sel(init_time=slice(start_time, end_time))
        .sel(lead_time=slice("0h", lead_times))
    )

    # Do spatial bounding box subset
    subset_zarr = auto_spatial_subset(ds=subset_zarr, site_metadata=site_metadata)

    # Select individual points using their integer indices
    subset_zarr = (
        subset_zarr
        .sel(latitude=site_metadata.latitude,
             longitude=site_metadata.longitude,
             method='nearest')
        .drop_vars(['latitude', 'longitude'])
    )

    return subset_zarr

def auto_spatial_subset(ds, site_metadata, buffer_deg=2.0, eps_km=1000):
    """
    Cluster site lat/lon, and build a bounding box per cluster with padding.
    
    Parameters:
        ds : xarray.Dataset
        site_metadata : xarray.Dataset or DataFrame with `latitude`, `longitude`, and `site_id`
        buffer_deg : float
            Degrees to buffer each bounding box
        eps_km : float
            Approximate clustering radius in kilometers

    Returns:
        ds_subset : spatially subsetted xarray.Dataset
    """

    # Extract lat/lon values in radians for haversine clustering
    latlon_rad = np.radians(np.column_stack([
        site_metadata.latitude.values,
        site_metadata.longitude.values
    ]))

    # Cluster with DBSCAN using haversine distance
    kms_per_radian = 6371.0088
    db = DBSCAN(eps=eps_km / kms_per_radian, min_samples=1, metric='haversine')
    labels = db.fit_predict(latlon_rad)

    site_df = pd.DataFrame({
        "lat": site_metadata.latitude.values,
        "lon": site_metadata.longitude.values,
        "cluster": labels
    })

    # Bounding box per cluster
    lat_ranges = []
    lon_ranges = []

    for label in np.unique(labels):
        group = site_df[site_df["cluster"] == label]
        lat_min, lat_max = group.lat.min() - buffer_deg, group.lat.max() + buffer_deg
        lon_min, lon_max = group.lon.min() - buffer_deg, group.lon.max() + buffer_deg
        lat_ranges.append((lat_min, lat_max))
        lon_ranges.append((lon_min, lon_max))

    # Combine all bounding boxes
    lat_min = min([r[0] for r in lat_ranges])
    lat_max = max([r[1] for r in lat_ranges])
    lon_min = min([r[0] for r in lon_ranges])
    lon_max = max([r[1] for r in lon_ranges])

    # Subset the dataset
    ds_subset = ds.sel(latitude=slice(lat_max, lat_min),
                       longitude=slice(lon_min, lon_max))
    
    return ds_subset


if __name__ == "__main__": 
    site_metadata_url = "https://raw.githubusercontent.com/eco4cast/usgsrc4cast-ci/main/USGS_site_metadata.csv"
    site_metadata = (
        pd.read_csv(site_metadata_url)
        .set_index('site_id')
        .to_xarray()
    )
    start_time = np.datetime64("2024-01-01") 
    end_time = np.datetime64("2024-01-10")

    variables = ["downward_long_wave_radiation_flux_surface", "downward_short_wave_radiation_flux_surface", "maximum_temperature_2m", "minimum_temperature_2m", "precipitation_surface", "temperature_2m", "total_cloud_cover_atmosphere", "wind_u_10m", "wind_v_10m"]
    
    gefs_analysis_zarr = pull_gefs_analysis(
        start_time=start_time,
        end_time=end_time,
        site_metadata=site_metadata,
        variables=variables,
        email="jzwart@usgs.gov"
    )

    print(gefs_analysis_zarr)

    lead_times = '10d'

    gefs_operational_zarr = pull_gefs_operational(
        start_time=start_time,
        end_time=end_time,
        site_metadata=site_metadata,
        lead_times=lead_times,
        variables=variables,
        email="jzwart@usgs.gov"
    )

    print(gefs_operational_zarr)

