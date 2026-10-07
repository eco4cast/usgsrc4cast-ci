"""
Produce native-resolution Stage 1 and Stage 1-stats products from dynamical.org
GEFS forecast data, matching the gefs4cast parquet schema.

Unlike Stage 2/3 (hourly, CF variable names), these products keep GEFS native
resolution (3 h to day 10, 6 h to day 35), GRIB variable names, and per-ensemble
structure.

Scope note: dynamical.org exposes 16 of the 25 GRIB variables gefs4cast carried.
The 9 land-surface / surface-flux variables it does not ingest (ICETK, LHTFL,
SHTFL, SNOD, SOILW, TSOIL, ULWRF, USWRF, WEASD) are intentionally dropped. The
`pseudo` product is not reproduced at all (it requires 31-member, 4-cycle short-
horizon forecasts that dynamical does not provide) and is deprecated.
"""

import numpy as np
import pandas as pd
import xarray as xr


# dynamical.org variable -> (GRIB name, transform to GRIB-convention units).
# A transform of None means identity. "APCP" is special-cased (rate -> interval
# accumulation) in _build_native_dataset because it depends on the lead spacing.
GRIB_VARIABLE_MAP = {
    "temperature_2m": ("TMP", lambda x: x + 273.15),              # °C -> K
    "maximum_temperature_2m": ("TMAX", lambda x: x + 273.15),     # °C -> K
    "minimum_temperature_2m": ("TMIN", lambda x: x + 273.15),     # °C -> K
    "relative_humidity_2m": ("RH", None),                         # %
    "pressure_surface": ("PRES", None),                           # Pa
    "wind_u_10m": ("UGRD", None),                                 # m/s
    "wind_v_10m": ("VGRD", None),                                 # m/s
    "precipitation_surface": ("APCP", "accumulate"),              # kg/m²/s -> kg/m² per interval
    "downward_short_wave_radiation_flux_surface": ("DSWRF", None),  # W/m²
    "downward_long_wave_radiation_flux_surface": ("DLWRF", None),   # W/m²
    "total_cloud_cover_atmosphere": ("TCDC", None),               # %
    "precipitable_water_atmosphere": ("PWAT", None),              # kg/m²
    "categorical_rain_surface": ("CRAIN", None),                  # 0/1
    "categorical_snow_surface": ("CSNOW", None),                  # 0/1
    "categorical_freezing_rain_surface": ("CFRZR", None),         # 0/1
    "categorical_ice_pellets_surface": ("CICEP", None),           # 0/1
}

# Stage 1 / stage1-stats long-format column order (file columns; site_id and
# reference_datetime are partition columns written by the parquet writer).
NATIVE_COLUMNS = [
    "ensemble", "cycle", "horizon", "datetime",
    "variable", "prediction", "family", "site_id",
]


def _ensemble_label(member: int) -> str:
    """GEFS member index -> gefs4cast ensemble label (0 -> gec00, n -> gepNN)."""
    return "gec00" if int(member) == 0 else f"gep{int(member):02d}"


def _build_native_dataset(forecast_ds: xr.Dataset) -> xr.Dataset:
    """
    Map a single-init forecast Dataset to GRIB-named variables in GRIB units.

    Returns a Dataset with dims (lead_time, ensemble_member, site_id) whose data
    variables are the GRIB names, plus a `datetime` coordinate on lead_time.
    """
    ds = forecast_ds
    if "init_time" in ds.dims and ds.sizes["init_time"] == 1:
        ds = ds.squeeze("init_time")
    init_time = pd.Timestamp(ds.init_time.values)

    lead = pd.to_timedelta(ds.lead_time.values)
    valid_times = init_time + lead

    # Per-interval length in seconds for accumulation (first interval = lead[0],
    # which is 0 h, so APCP at lead 0 is 0 — matching GEFS).
    interval_s = np.diff(lead.total_seconds(), prepend=0.0)
    interval_da = xr.DataArray(interval_s, dims="lead_time",
                               coords={"lead_time": ds.lead_time})

    out = xr.Dataset()
    for dyn_var, (grib, transform) in GRIB_VARIABLE_MAP.items():
        if dyn_var not in ds.data_vars:
            continue
        da = ds[dyn_var]
        if transform == "accumulate":
            da = da * interval_da          # rate (kg/m²/s) -> kg/m² over interval
        elif transform is not None:
            da = transform(da)
        out[grib] = da

    out = out.assign_coords(datetime=("lead_time", valid_times))
    out.attrs["init_time"] = init_time
    return out


def _native_to_long(native: xr.Dataset, ensemble_dim: str,
                    ensemble_labels: dict, family: str) -> pd.DataFrame:
    """
    Melt a native GRIB-named Dataset to the long Stage 1 schema.

    Parameters
    ----------
    native : xr.Dataset
        Output of _build_native_dataset (or its ensemble reduction), with a
        `datetime` coord on lead_time and an ensemble dimension.
    ensemble_dim : str
        Name of the ensemble dimension (e.g. "ensemble_member" or "ensemble").
    ensemble_labels : dict
        Map from ensemble coordinate value to its string label.
    family : str
        Value for the `family` column ("ensemble" or "spread").
    """
    init_time = native.attrs["init_time"]

    df = native.to_dataframe().reset_index()
    grib_vars = list(native.data_vars)

    df = df.melt(
        id_vars=["lead_time", ensemble_dim, "site_id", "datetime"],
        value_vars=grib_vars,
        var_name="variable",
        value_name="prediction",
    )

    df["ensemble"] = df[ensemble_dim].map(ensemble_labels)
    df["cycle"] = init_time.strftime("%H")
    df["horizon"] = pd.to_timedelta(df["lead_time"])
    df["family"] = family

    return df[NATIVE_COLUMNS]


def process_forecast_to_stage1(forecast_ds: xr.Dataset) -> pd.DataFrame:
    """
    Produce the Stage 1 (per-ensemble, native resolution) long DataFrame.

    Columns: ensemble, cycle, horizon, datetime, variable, prediction, family,
    site_id. 31 ensemble members labelled gec00/gep01..gep30, GRIB variable
    names, GRIB-convention units.
    """
    native = _build_native_dataset(forecast_ds)
    members = native["ensemble_member"].values
    labels = {m: _ensemble_label(m) for m in members}
    return _native_to_long(native, "ensemble_member", labels, family="ensemble")


def process_forecast_to_stage1_stats(forecast_ds: xr.Dataset) -> pd.DataFrame:
    """
    Produce the Stage 1-stats (ensemble mean/spread) long DataFrame.

    Computes the ensemble mean (geavg) and spread (gespr, population std dev)
    across the 31 members, in GRIB units. family column is "spread" to match the
    gefs4cast stage1-stats product.
    """
    native = _build_native_dataset(forecast_ds)

    mean = native.mean("ensemble_member")
    spread = native.std("ensemble_member", ddof=0)
    stats = xr.concat([mean, spread], dim="ensemble")
    stats = stats.assign_coords(ensemble=["geavg", "gespr"])
    stats.attrs["init_time"] = native.attrs["init_time"]

    labels = {"geavg": "geavg", "gespr": "gespr"}
    return _native_to_long(stats, "ensemble", labels, family="spread")
