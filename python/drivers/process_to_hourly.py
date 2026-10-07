"""
Process dynamical.org GEFS data to hourly resolution with CF variable names.

Ported from R/eco4cast-helpers/to_hourly.R. Takes xarray Datasets from
dynamical.org and produces pandas DataFrames matching the Stage 2/3 parquet
schema used by the forecasting challenge.
"""

import numpy as np
import pandas as pd
import xarray as xr

from .solar_geometry import potential_solar_radiation


# dynamical.org variable -> (CF output name, unit transform function)
# Transform converts dynamical units to challenge Stage 2/3 units
VARIABLE_TRANSFORMS = {
    "temperature_2m": ("air_temperature", lambda x: x + 273.15),         # °C -> K
    "pressure_surface": ("air_pressure", lambda x: x),                   # Pa -> Pa
    "relative_humidity_2m": ("relative_humidity", lambda x: x / 100),    # % -> fraction
    "wind_u_10m": ("northward_wind", lambda x: x),                       # m/s -> m/s
    "wind_v_10m": ("eastward_wind", lambda x: x),                        # m/s -> m/s
    "precipitation_surface": ("precipitation_flux", lambda x: x),        # kg/m²/s (== mm/s) -> kg/m²/s
    "downward_short_wave_radiation_flux_surface": (
        "surface_downwelling_shortwave_flux_in_air", lambda x: x),       # W/m² -> W/m²
    "downward_long_wave_radiation_flux_surface": (
        "surface_downwelling_longwave_flux_in_air", lambda x: x),        # W/m² -> W/m²
}

# State variables get linear interpolation to hourly
STATE_VARS = {"temperature_2m", "pressure_surface", "relative_humidity_2m",
              "wind_u_10m", "wind_v_10m"}

# Flux variables get forward-fill to hourly
FLUX_VARS = {"precipitation_surface",
             "downward_short_wave_radiation_flux_surface",
             "downward_long_wave_radiation_flux_surface"}


def _interpolate_to_hourly(ds: xr.Dataset, time_dim: str = "time") -> xr.Dataset:
    """
    Interpolate dataset to hourly resolution.

    State variables use linear interpolation.
    Flux variables use forward-fill.

    Parameters
    ----------
    ds : xr.Dataset
        Input dataset with 3h/6h temporal resolution.
    time_dim : str
        Name of the time dimension.

    Returns
    -------
    xr.Dataset
        Hourly dataset.
    """
    times = pd.DatetimeIndex(ds[time_dim].values)
    hourly_times = pd.date_range(times.min(), times.max(), freq="1h")

    state_var_names = [v for v in ds.data_vars if v in STATE_VARS]
    flux_var_names = [v for v in ds.data_vars if v in FLUX_VARS]

    parts = []

    if state_var_names:
        states = ds[state_var_names].interp(
            {time_dim: hourly_times}, method="linear"
        )
        parts.append(states)

    if flux_var_names:
        # GEFS fluxes (APCP, DSWRF, DLWRF) are backward-looking averages labeled at
        # the END of the native interval (e.g. the 3h value is the mean over hours
        # 0-3). Backfill assigns each interval mean to the hours it covers, matching
        # the production R pipeline (to_hourly.R uses tidyr::fill(.direction="up")).
        # Forward-fill would shift fluxes one native step late and NaN the leading hours.
        flux_ds = ds[flux_var_names]
        # Drop native steps that are entirely missing (GEFS has no "previous step" at
        # lead 0, so its flux is NaN). Removing it makes the leading hours ABSENT from
        # the index so reindex(method="bfill") carries the first real interval back
        # over them, instead of leaving a present-but-NaN lead-0 as a leading NaN.
        flux_ds = flux_ds.dropna(dim=time_dim, how="all")
        fluxes = flux_ds.reindex({time_dim: hourly_times}, method="bfill")
        parts.append(fluxes)

    return xr.merge(parts)


def _apply_solar_geometry(hourly_ds: xr.Dataset,
                          site_lats: dict,
                          site_lons: dict,
                          time_dim: str = "time") -> xr.Dataset:
    """
    Apply solar geometry correction to shortwave radiation.

    Redistributes DSWRF values using potential radiation from solar geometry,
    preserving daily totals while adjusting hourly distribution.

    Parameters
    ----------
    hourly_ds : xr.Dataset
        Hourly dataset containing downward_short_wave_radiation_flux_surface.
    site_lats : dict
        {site_id: latitude} mapping.
    site_lons : dict
        {site_id: longitude} mapping.
    time_dim : str
        Name of the time dimension.

    Returns
    -------
    xr.Dataset
        Dataset with corrected shortwave radiation.
    """
    sw_var = "downward_short_wave_radiation_flux_surface"
    if sw_var not in hourly_ds.data_vars:
        return hourly_ds

    ds = hourly_ds.copy(deep=True)

    # Ensure data is loaded into memory for in-place modification
    ds.load()

    # Get dimension order for the sw variable
    sw_da = ds[sw_var]
    dim_names = sw_da.dims
    time_axis = dim_names.index(time_dim)
    site_axis = dim_names.index("site_id")
    has_ensemble = "ensemble_member" in dim_names
    ens_axis = dim_names.index("ensemble_member") if has_ensemble else None

    sw = sw_da.values  # numpy array, now in memory

    times = pd.DatetimeIndex(ds[time_dim].values)
    doy_frac = times.dayofyear + times.hour / 24.0
    dates = times.date
    unique_dates = np.unique(dates)

    site_ids = ds.site_id.values

    for si, sid in enumerate(site_ids):
        lat = site_lats[sid]
        lon = site_lons[sid]
        lon360 = lon + 360 if lon < 0 else lon

        rpot = potential_solar_radiation(doy_frac.values, lon360, lat)

        for d in unique_dates:
            mask = dates == d
            rpot_day = rpot[mask]
            avg_rpot = np.mean(rpot_day)

            if avg_rpot <= 0.0:
                continue

            # Build numpy indexer for this site + day
            # Use np.take / fancy indexing based on actual dimension order
            time_idx = np.where(mask)[0]

            if has_ensemble:
                # Get the slice for this site and day across all ensembles
                # Build a generic indexer
                idx = [slice(None)] * sw.ndim
                idx[time_axis] = time_idx
                idx[site_axis] = si
                day_vals = sw[tuple(idx)]  # shape: (n_hours, n_ens) or (n_ens, n_hours)

                avg_sw = np.mean(day_vals)
                scale = avg_sw / avg_rpot

                # rpot_day needs to be broadcast along the time axis
                corrected = rpot_day * scale
                # Broadcast to match ensemble dimension
                if time_axis < ens_axis:
                    corrected = corrected[:, np.newaxis]  # (n_hours, 1)
                else:
                    corrected = corrected[np.newaxis, :]  # (1, n_hours)
                corrected = np.broadcast_to(corrected, day_vals.shape)

                sw[tuple(idx)] = corrected
            else:
                idx = [slice(None)] * sw.ndim
                idx[time_axis] = time_idx
                idx[site_axis] = si
                day_vals = sw[tuple(idx)]

                avg_sw = np.mean(day_vals)
                sw[tuple(idx)] = rpot_day * (avg_sw / avg_rpot)

    ds[sw_var] = xr.DataArray(sw, dims=dim_names, coords=sw_da.coords)
    return ds


def _ds_to_long_df(ds: xr.Dataset, reference_datetime,
                   time_dim: str = "time",
                   ensemble_dim: str = None) -> pd.DataFrame:
    """
    Convert xarray Dataset to long-format DataFrame matching Stage 2/3 schema.

    Output columns: site_id, datetime, variable, prediction, parameter,
                    reference_datetime, family

    Parameters
    ----------
    ds : xr.Dataset
        Processed hourly dataset.
    reference_datetime : str or pd.NaT
        Forecast reference datetime (NaT for stage3/pseudo).
    time_dim : str
        Name of the time dimension.
    ensemble_dim : str or None
        Name of the ensemble dimension (None for analysis data).

    Returns
    -------
    pd.DataFrame
    """
    rows = []

    for dyn_var in ds.data_vars:
        if dyn_var not in VARIABLE_TRANSFORMS:
            continue

        cf_name, transform = VARIABLE_TRANSFORMS[dyn_var]
        da = ds[dyn_var]

        times = pd.DatetimeIndex(da[time_dim].values)
        site_ids = da.site_id.values

        if ensemble_dim and ensemble_dim in da.dims:
            ensembles = da[ensemble_dim].values
            for sid in site_ids:
                for ens in ensembles:
                    vals = da.sel(site_id=sid, **{ensemble_dim: ens}).values
                    vals = transform(vals)
                    rows.append(pd.DataFrame({
                        "site_id": sid,
                        "datetime": times,
                        "variable": cf_name,
                        "prediction": vals,
                        "parameter": int(ens),
                        "reference_datetime": reference_datetime,
                        "family": "ensemble",
                    }))
        else:
            for sid in site_ids:
                vals = da.sel(site_id=sid).values
                vals = transform(vals)
                rows.append(pd.DataFrame({
                    "site_id": sid,
                    "datetime": times,
                    "variable": cf_name,
                    "prediction": vals,
                    "parameter": 0,
                    "reference_datetime": reference_datetime,
                    "family": "ensemble",
                }))

    df = pd.concat(rows, ignore_index=True)
    return df


def process_forecast_to_stage2(forecast_ds: xr.Dataset,
                               site_lats: dict,
                               site_lons: dict) -> pd.DataFrame:
    """
    Process dynamical.org forecast data to Stage 2 format.

    Steps:
    1. Compute valid times from init_time + lead_time
    2. Interpolate to hourly
    3. Apply solar geometry correction
    4. Apply variable transforms
    5. Convert to long-format DataFrame

    Parameters
    ----------
    forecast_ds : xr.Dataset
        Dynamical.org forecast dataset (dims: lead_time, ensemble_member, site_id).
    site_lats : dict
        {site_id: latitude}.
    site_lons : dict
        {site_id: longitude}.

    Returns
    -------
    pd.DataFrame
        Stage 2 formatted DataFrame.
    """
    # Squeeze init_time if it's a dimension (single forecast date)
    ds = forecast_ds
    if "init_time" in ds.dims and ds.sizes["init_time"] == 1:
        ds = ds.squeeze("init_time")
    init_time = pd.Timestamp(ds.init_time.values)
    reference_datetime = init_time.strftime("%Y-%m-%d")

    # Convert lead_time to valid times
    lead_times = ds.lead_time.values
    valid_times = init_time + lead_times
    ds = ds.assign_coords(time=("lead_time", valid_times))
    ds = ds.swap_dims({"lead_time": "time"}).drop_vars("lead_time")

    # Interpolate to hourly
    ds_hourly = _interpolate_to_hourly(ds, time_dim="time")

    # Apply solar geometry correction
    ds_hourly = _apply_solar_geometry(ds_hourly, site_lats, site_lons, time_dim="time")

    # Convert to long DataFrame
    df = _ds_to_long_df(ds_hourly, reference_datetime=reference_datetime,
                        time_dim="time", ensemble_dim="ensemble_member")

    return df


def process_analysis_to_stage3(analysis_ds: xr.Dataset,
                               site_lats: dict,
                               site_lons: dict) -> pd.DataFrame:
    """
    Process dynamical.org analysis data to Stage 3 format.

    Steps:
    1. Interpolate to hourly
    2. Apply solar geometry correction
    3. Apply variable transforms
    4. Convert to long-format DataFrame (reference_datetime = NaT)

    Parameters
    ----------
    analysis_ds : xr.Dataset
        Dynamical.org analysis dataset (dims: time, site_id).
    site_lats : dict
        {site_id: latitude}.
    site_lons : dict
        {site_id: longitude}.

    Returns
    -------
    pd.DataFrame
        Stage 3 formatted DataFrame.
    """
    # Interpolate to hourly
    ds_hourly = _interpolate_to_hourly(analysis_ds, time_dim="time")

    # Apply solar geometry correction
    ds_hourly = _apply_solar_geometry(ds_hourly, site_lats, site_lons, time_dim="time")

    # Convert to long DataFrame — no ensemble, reference_datetime is NA
    df = _ds_to_long_df(ds_hourly, reference_datetime=pd.NaT,
                        time_dim="time", ensemble_dim=None)

    return df
