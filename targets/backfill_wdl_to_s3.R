# Recurring (quarterly) WDL backfill for the CA DWR sites.
#
# CA DWR republishes reviewed continuous chlorophyll to the Water Data Library
# (WDL) every ~2 months. This job runs every 3 months (see
# .github/workflows/wdl_backfill.yaml) and upgrades the S3 historic targets file
# with that reviewed data, following the EDI > WDL > CDEC precedence:
#
#   * EDI is authoritative and is NEVER overwritten. EDI-covered (site, day)
#     records — built from the local packages under targets/in/ — are protected.
#   * WDL replaces the provisional CDEC value on any (site, day) it covers that
#     EDI does not, and fills days neither EDI nor CDEC had.
#   * CDEC near-real-time data is preserved everywhere WDL has nothing (notably
#     the most recent days, which WDL lags behind), so forecasts stay scoreable.
#
# Only DWR-* rows are touched; USGS rows are left exactly as-is. Unlike the
# one-time backfill_dwr_to_s3.R (inspect-then-upload), this recurring job pushes
# to S3 directly, guarded so an empty/failed WDL pull is a no-op rather than a
# destructive overwrite. Run from targets/:  Rscript backfill_wdl_to_s3.R

suppressMessages(library(tidyverse))

source("src/read_edi_data.R")       # build_edi_chla() -> protected EDI coverage
source("src/download_wdl_data.R")   # download_wdl_chla_data(), WDL_CHLA_STATIONS
source("src/s3_utils.R")            # push_to_s3()

config  <- yaml::read_yaml("../challenge_configuration.yaml")
edi_dir <- "in"
today   <- Sys.Date()
# WDL blobs are period-of-record; a generous floor captures the full reviewed
# record. EDI still wins the deep-history overlap, so this only affects the
# post-EDI tail (plus MLS, which has no EDI).
wdl_floor <- as.Date("2005-01-01")

# --- EDI coverage: the protected (site, day) set (never overwritten) ---------
edi <- build_edi_chla(edi_dir)
message("EDI protected records: ", nrow(edi),
        " across ", dplyr::n_distinct(edi$site_id), " sites")

# --- WDL reviewed continuous pull -------------------------------------------
wdl_raw <- download_wdl_chla_data(
  stations = WDL_CHLA_STATIONS, start_date = wdl_floor, end_date = today,
  out_file = tempfile(fileext = ".rds")
) |> read_rds()

wdl_fmt <- wdl_raw |>
  transmute(project_id = "usgsrc4cast",
            site_id = paste0("DWR-", site_no),
            datetime = dateTime,
            duration = "P1D",
            variable = "chla",
            observation = chl_ug_L)

# EDI > WDL: drop any (site, day) EDI already covers, so EDI is never overwritten.
wdl_fill <- anti_join(wdl_fmt, edi, by = c("site_id", "datetime"))
message("WDL rows pulled: ", nrow(wdl_fmt),
        " | kept after EDI precedence: ", nrow(wdl_fill))
if (nrow(wdl_fill) > 0) {
  wdl_fill |>
    group_by(site_id) |>
    summarise(n = n(), first = min(datetime), last = max(datetime),
              .groups = "drop") |>
    as.data.frame() |> print()
}

# Guard: an empty pull means blob outage / no new reviewed data. Skip the push
# rather than re-uploading an unchanged file (or risking a destructive no-data
# overwrite). The next quarterly run will pick the data up.
if (nrow(wdl_fill) == 0) {
  message("No WDL data available after EDI precedence; skipping S3 push.")
  quit(save = "no", status = 0)
}

# --- Merge into live S3 historic (WDL replaces CDEC on overlap; EDI/CDEC/USGS
#     rows preserved) -----------------------------------------------------------
s3_url <- config$target_groups$aquatics$targets_file
message("\nReading current S3 historic file: ", s3_url)
s3 <- read_csv(s3_url, show_col_types = FALSE)

combined <- bind_rows(
  anti_join(s3, wdl_fill, by = c("site_id", "datetime")),  # keep EDI, CDEC-only, USGS
  wdl_fill                                                  # reviewed WDL wins its days
) |>
  arrange(site_id, datetime)

# Invariant: never touch non-DWR (USGS) rows.
usgs_before <- sum(!startsWith(s3$site_id, "DWR-"))
usgs_after  <- sum(!startsWith(combined$site_id, "DWR-"))
if (usgs_before != usgs_after) {
  stop("USGS row count changed (", usgs_before, " -> ", usgs_after,
       "); WDL backfill must not touch non-DWR sites.")
}

# Invariant: EDI-covered days must survive unchanged (WDL must not overwrite EDI).
edi_in_s3 <- semi_join(s3, edi, by = c("site_id", "datetime"))
edi_after <- semi_join(combined, edi_in_s3, by = c("site_id", "datetime", "observation"))
if (nrow(edi_after) != nrow(edi_in_s3)) {
  stop("EDI-covered rows changed (", nrow(edi_in_s3), " -> ", nrow(edi_after),
       "); WDL backfill must not overwrite EDI data.")
}

message("\nCombined rows: ", nrow(combined),
        " (S3 had ", nrow(s3), "; DWR rows now ",
        sum(startsWith(combined$site_id, "DWR-")), ")")

out_file <- "out/historic_data_wdl_backfilled.csv"
write_csv(combined, out_file)

push_to_s3(
  config = config,
  local_file_name = out_file,
  s3_file_name = config$targets_file_name)
message("Pushed WDL-backfilled historic targets to S3: ", config$targets_file_name)
