# Download CA DWR chlorophyll-a data from the CDEC (California Data Exchange
# Center) CSV service and aggregate to daily means for the forecasting challenge.
#
# CDEC chlorophyll is sensor number 28 (CHLORPH, ug/L). Sensor numbers are not
# globally consistent across stations, so this is verified for the challenge's
# DWR sites (see docs/add_cadwr_cdec_sites.md). Note: CDEC data is real-time and
# never QC'd, so we drop non-numeric / negative values and de-duplicate to a
# daily mean. Timestamps are treated as Pacific Standard Time (CDEC convention,
# no DST) for the purpose of assigning a daily date.

fetch_cdec_csv <- function(url, max_tries = 5, base_sleep = 2) {
  # CDEC's CSV servlet is prone to timeouts (see Nick Framsted's notes in
  # docs/add_cadwr_cdec_sites.md), so retry with exponential backoff.
  old_timeout <- getOption("timeout")
  options(timeout = max(120, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)

  for (attempt in seq_len(max_tries)) {
    result <- tryCatch(
      readr::read_csv(url, show_col_types = FALSE, progress = FALSE),
      error = function(e) e
    )
    if (!inherits(result, "error") && nrow(result) > 0) {
      return(result)
    }
    if (attempt < max_tries) {
      Sys.sleep(base_sleep * 2^(attempt - 1))
    }
  }
  warning("CDEC download failed after ", max_tries, " attempts: ", url)
  return(NULL)
}

download_cdec_chla_data <- function(
    stations,
    start_date,
    end_date,
    sensor_num = 28,
    dur_code = "E",
    min_chl = 0,
    max_tries = 5,
    sleep_between = 5,
    out_file
){
  empty <- tibble::tibble(site_no = character(),
                          dateTime = as.Date(character()),
                          chl_ug_L = numeric())

  if (length(stations) == 0) {
    readr::write_rds(empty, out_file)
    return(out_file)
  }

  # One request per station keeps URLs small and isolates per-station failures.
  # A short pause between stations avoids CDEC rate-limiting, which otherwise
  # returns an "Empty reply from server" on rapid successive requests.
  raw <- purrr::imap(stations, function(stn, i) {
    if (i > 1) Sys.sleep(sleep_between)
    url <- paste0(
      "https://cdec.water.ca.gov/dynamicapp/req/CSVDataServlet",
      "?Stations=", stn,
      "&SensorNums=", sensor_num,
      "&dur_code=", dur_code,
      "&Start=", format(as.Date(start_date), "%Y-%m-%d"),
      "&End=", format(as.Date(end_date), "%Y-%m-%d")
    )
    fetch_cdec_csv(url, max_tries = max_tries)
  }) |>
    purrr::compact() |>
    purrr::list_rbind()

  if (nrow(raw) == 0) {
    readr::write_rds(empty, out_file)
    return(out_file)
  }

  daily_data <- raw |>
    rename(site_no = STATION_ID,
           datetime_raw = `DATE TIME`,
           value = VALUE) |>
    mutate(value = suppressWarnings(as.numeric(value))) |>
    filter(!is.na(value), value >= min_chl) |>
    # CDEC "DATE TIME" is Pacific clock time; readr parses it as a naive
    # POSIXct (wall-clock preserved in UTC), so as.Date() yields the local date.
    mutate(dateTime = as.Date(datetime_raw)) |>
    filter(!is.na(dateTime)) |>
    group_by(site_no, dateTime) |>
    summarise(chl_ug_L = mean(value), .groups = "drop")

  readr::write_rds(daily_data, out_file)
  return(out_file)
}
