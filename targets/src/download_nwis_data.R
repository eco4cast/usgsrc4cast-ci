chunk_time_range <- function(start_date, end_date, chunk_years = 3) {
  start_date <- as.Date(start_date)
  end_date <- as.Date(end_date)
  starts <- seq(start_date, end_date, by = paste0(chunk_years, " years"))
  ends <- c(starts[-1] - 1, end_date)
  mapply(function(s, e) c(as.character(s), as.character(e)),
         starts, ends, SIMPLIFY = FALSE)
}

nwis_tz_to_olson <- function(tz_abbr, uses_dst) {
  # Map NWIS timezone abbreviations to Olson names
  # uses_dst: "Y" or "N" — determines whether to use the DST-aware zone
  dplyr::case_when(
    tz_abbr == "EST" & uses_dst == "Y" ~ "America/New_York",
    tz_abbr == "EST" & uses_dst == "N" ~ "Etc/GMT+5",
    tz_abbr == "CST" & uses_dst == "Y" ~ "America/Chicago",
    tz_abbr == "CST" & uses_dst == "N" ~ "Etc/GMT+6",
    tz_abbr == "MST" & uses_dst == "Y" ~ "America/Denver",
    tz_abbr == "MST" & uses_dst == "N" ~ "Etc/GMT+7",
    tz_abbr == "PST" & uses_dst == "Y" ~ "America/Los_Angeles",
    tz_abbr == "PST" & uses_dst == "N" ~ "Etc/GMT+8",
    TRUE ~ "UTC"
  )
}

get_site_timezones <- function(sites_prefixed) {
  dataRetrieval::read_waterdata_monitoring_location(
    monitoring_location_id = sites_prefixed
  ) |>
    sf::st_drop_geometry() |>
    mutate(tz_olson = nwis_tz_to_olson(time_zone_abbreviation,
                                       uses_daylight_savings)) |>
    select(monitoring_location_id, tz_olson)
}

assign_local_date <- function(df, site_tz_lookup) {
  # Convert UTC timestamps to site-local dates for daily aggregation
  # as.Date() on POSIXct ignores timezone, so format to string first
  df |>
    left_join(site_tz_lookup, by = "monitoring_location_id") |>
    mutate(dateTime = purrr::map2_vec(
      time, tz_olson,
      \(t, tz) as.Date(format(lubridate::with_tz(t, tzone = tz), "%Y-%m-%d"))
    )) |>
    select(-tz_olson)
}

download_historic_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    statistic_id = "00003",
    min_chl = 0,
    out_file
){
  sites_prefixed <- paste0("USGS-", sites)

  daily_data <- dataRetrieval::read_waterdata_daily(
    monitoring_location_id = sites_prefixed,
    parameter_code = pcodes,
    statistic_id = statistic_id,
    time = c(as.character(start_date), as.character(end_date))
  ) |>
    sf::st_drop_geometry() |>
    filter(!is.na(value), value >= min_chl) |>
    mutate(site_no = gsub("USGS-", "", monitoring_location_id),
           dateTime = as.Date(time)) |>
    group_by(site_no, dateTime) |>
    summarise(chl_ug_L = mean(value), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}

download_historic_uv_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    min_chl = 0,
    out_file
){
  if (length(sites) == 0) {
    daily_data <- tibble(site_no = character(),
                         dateTime = as.Date(character()),
                         chl_ug_L = numeric())
    write_rds(x = daily_data, file = out_file)
    return(out_file)
  }

  sites_prefixed <- paste0("USGS-", sites)
  time_chunks <- chunk_time_range(start_date, end_date)
  site_tz <- get_site_timezones(sites_prefixed)

  daily_data <- purrr::map(time_chunks, function(time_window) {
    dataRetrieval::read_waterdata_continuous(
      monitoring_location_id = sites_prefixed,
      parameter_code = pcodes,
      time = time_window
    )
  }) |>
    list_rbind() |>
    filter(!is.na(value), value >= min_chl) |>
    assign_local_date(site_tz) |>
    mutate(site_no = gsub("USGS-", "", monitoring_location_id)) |>
    group_by(site_no, dateTime) |>
    summarise(chl_ug_L = mean(value), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}

download_historic_uv_rfu_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    min_chl = 0,
    out_file
){
  sites_prefixed <- paste0("USGS-", sites)
  time_chunks <- chunk_time_range(start_date, end_date)
  site_tz <- get_site_timezones(sites_prefixed)

  daily_data <- purrr::map(time_chunks, function(time_window) {
    dataRetrieval::read_waterdata_continuous(
      monitoring_location_id = sites_prefixed,
      parameter_code = pcodes,
      time = time_window
    )
  }) |>
    list_rbind() |>
    filter(!is.na(value), value >= min_chl) |>
    assign_local_date(site_tz) |>
    mutate(site_no = gsub("USGS-", "", monitoring_location_id),
           chl_ug_L = case_when(site_no == "14211010" ~ value * 4 - 0.2,
                                TRUE ~ value * 4),
           chl_ug_L = ifelse(chl_ug_L < 0, 0, chl_ug_L)) |>
    group_by(site_no, dateTime) |>
    summarise(chl_ug_L = mean(chl_ug_L), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}
