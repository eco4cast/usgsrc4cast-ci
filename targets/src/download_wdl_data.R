# Download CA DWR reviewed continuous chlorophyll-a from the Water Data Library
# (WDL) and aggregate to daily means for the forecasting challenge. This is the
# middle (WDL) layer of the EDI > WDL > CDEC source stack for the CA DWR Delta
# sites (see docs/add_cadwr_cdec_sites.md): reviewed/QA-QC'd continuous data that
# DWR republishes every ~2 months, used to upgrade the provisional CDEC tail on
# overlapping days once reviewed values become available.
#
# Access: WDL continuous traces are Azure blobs, discoverable via the CNRA
# station-trace-download-links table (parameter == "Chlorophyll"). The blob URL
# pattern is stable, so we address stations directly rather than re-parsing that
# table each run:
#   https://wdlstorageaccount.blob.core.windows.net/wdlcontinuous/{stn}/por/{stn}_Chlorophyll_RAW.csv
#
# Station -> CDEC-code crosswalk (verified 2026-08-28 against the CNRA
# station-trace-download-links table). Keyed by the CDEC site code used
# everywhere else in the pipeline so paste0("DWR-", site_no) yields DWR-GLE etc.
#   GLE = B9532000   OH1 = B9540000   MHO = B9553100   MLS = B9567000
# SJR has no continuous WDL chlorophyll trace (confirmed by CA DWR); it stays
# EDI + CDEC only. MHO and MLS became available in the CNRA table after the
# original 2026-08-18 pass, so all four are now WDL-covered.
#
# ROBUSTNESS: the blob endpoints are flaky -- they intermittently return HTTP 200
# with a zero-byte body, the "DAYMEAN" variant is mislabeled (contains raw points)
# and downloads truncated, and content-length can be short. So we (a) use the RAW
# trace and aggregate to daily means ourselves (matching the EDI/CDEC readers),
# (b) retry with backoff and treat an empty/too-small body as a failure, and
# (c) return an empty tibble for a station that never yields data rather than a
# partial one. Because the caller applies EDI > WDL > CDEC precedence per
# (site, day), a missing WDL day simply falls back to CDEC -- WDL can only add or
# upgrade observations, never remove them.

WDL_CHLA_STATIONS <- c(
  GLE = "B9532000",
  OH1 = "B9540000",
  MHO = "B9553100",
  MLS = "B9567000"
)

wdl_chla_url <- function(station) {
  paste0("https://wdlstorageaccount.blob.core.windows.net/wdlcontinuous/",
         station, "/por/", station, "_Chlorophyll_RAW.csv")
}

# Fetch one WDL RAW trace, retrying on the intermittent empty/short responses the
# blob endpoint returns. Returns the raw text (character scalar) or NULL.
fetch_wdl_raw <- function(url, max_tries = 6, base_sleep = 2, min_bytes = 200) {
  old_timeout <- getOption("timeout")
  options(timeout = max(180, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)

  for (attempt in seq_len(max_tries)) {
    txt <- tryCatch(
      paste(readLines(url, warn = FALSE), collapse = "\n"),
      error = function(e) NULL
    )
    # A valid trace has a 3-line header + data; the blob sometimes 200s with an
    # empty or truncated body, so require a plausible minimum size before trusting it.
    if (!is.null(txt) && nchar(txt) >= min_bytes) {
      return(txt)
    }
    if (attempt < max_tries) Sys.sleep(base_sleep * 2^(attempt - 1))
  }
  warning("WDL download failed/empty after ", max_tries, " attempts: ", url)
  NULL
}

# Parse one WDL RAW chlorophyll trace -> daily mean chla for the given window.
# WDL RAW format: 3 header lines, then "MM/DD/YYYY HH:MM:SS, value, qual, meta".
# qual 1/2 = good (matching Nick's DWR_NCRO_south_delta_data_pull.R); other codes
# (e.g. 40, 170) flag suspect values and are dropped.
parse_wdl_raw <- function(txt, site_no, start_date, end_date, min_chl = 0,
                          good_qual = c(1, 2)) {
  empty <- tibble::tibble(site_no = character(),
                          dateTime = as.Date(character()),
                          chl_ug_L = numeric())
  parsed <- tryCatch(
    readr::read_csv(
      I(txt), skip = 3, col_names = c("datetime_raw", "value", "qual", "meta"),
      col_types = readr::cols(datetime_raw = readr::col_character(),
                              value = readr::col_double(),
                              qual = readr::col_double(),
                              meta = readr::col_character()),
      show_col_types = FALSE, progress = FALSE
    ),
    error = function(e) NULL
  )
  if (is.null(parsed) || nrow(parsed) == 0) return(empty)

  parsed |>
    dplyr::mutate(dateTime = as.Date(lubridate::mdy_hms(datetime_raw))) |>
    dplyr::filter(!is.na(dateTime),
                  !is.na(value), value >= min_chl,
                  qual %in% good_qual,
                  dateTime >= as.Date(start_date),
                  dateTime <= as.Date(end_date)) |>
    dplyr::group_by(dateTime) |>
    dplyr::summarise(chl_ug_L = mean(value), .groups = "drop") |>
    dplyr::mutate(site_no = site_no) |>
    dplyr::select(site_no, dateTime, chl_ug_L)
}

# Build the daily WDL chla record for the requested stations over [start,end].
# `stations` is a named character vector: names = CDEC site codes (GLE/OH1/...),
# values = WDL station numbers (B9532000/...). Returns tibble(site_no, dateTime,
# chl_ug_L) with site_no = CDEC code, matching download_cdec_chla_data() so it
# drops straight into the same downstream rename/prefix logic.
download_wdl_chla_data <- function(
    stations = WDL_CHLA_STATIONS,
    start_date,
    end_date,
    min_chl = 0,
    max_tries = 6,
    sleep_between = 3,
    out_file
){
  empty <- tibble::tibble(site_no = character(),
                          dateTime = as.Date(character()),
                          chl_ug_L = numeric())

  if (length(stations) == 0) {
    readr::write_rds(empty, out_file)
    return(out_file)
  }

  codes <- names(stations)
  daily <- purrr::imap(stations, function(stn, code) {
    if (which(stations == stn)[1] > 1) Sys.sleep(sleep_between)
    txt <- fetch_wdl_raw(wdl_chla_url(stn), max_tries = max_tries)
    if (is.null(txt)) return(empty)
    # `code` is the name (CDEC code) when `stations` is named; guard for safety.
    site_code <- if (is.character(code) && nzchar(code)) code else stn
    parse_wdl_raw(txt, site_no = site_code,
                  start_date = start_date, end_date = end_date, min_chl = min_chl)
  }) |>
    purrr::list_rbind()

  if (nrow(daily) == 0) daily <- empty
  readr::write_rds(daily, out_file)
  return(out_file)
}
