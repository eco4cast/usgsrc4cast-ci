library(targets)

options(tidyverse.quiet = TRUE,
        clustermq.scheduler = "multicore")

tar_option_set(packages = c("dataRetrieval",
                            "tidyverse",
                            "sf",
                            "lubridate"))

source("src/download_nwis_data.R")
source("src/s3_utils.R")

list(

  tar_target(
    config_file,
    "../challenge_configuration.yaml",
    format = "file"
  ),

  tar_target(
    config,
    yaml::read_yaml(config_file)
  ),

  tar_target(
    site_list_file,
    "in/FY23_ecological_forecast_challenge_USGS_sites.csv",
    format = "file"
  ),

  tar_target(
    site_list_id,
    read_csv(site_list_file) |>
      filter(include_in_challenge == "yes") |>
      pull(NWIS_site_no)
  ),

  tar_target(
    metadata,
    {
      out_file <- "out/USGS_site_metadata.csv"
      sites_prefixed <- paste0("USGS-", site_list_id)
      site_meta <- read_waterdata_monitoring_location(
        monitoring_location_id = sites_prefixed
      )
      coords <- sf::st_coordinates(site_meta)
      site_meta |>
        sf::st_drop_geometry() |>
        mutate(latitude = coords[, "Y"],
               longitude = coords[, "X"],
               site_id = monitoring_location_id,
               project_id = "usgsrc4cast",
               site_url = paste0("https://waterdata.usgs.gov/monitoring-location/",
                                 gsub("USGS-", "", monitoring_location_id))) |>
        select(site_id, project_id, latitude, longitude, site_url) |>
        write_csv(file = out_file)
      return(out_file)
    }
  ),

  tar_target(
    start_date,
    as.Date("2000-01-01")
  ),

  tar_target(
    end_date,
    Sys.Date(),
    cue = tar_cue("always")
  ),

  tar_target(
    pcodes_yml,
    "in/pcodes.yml",
    format = "file"
  ),

  tar_target(
    pcodes_ugL,
    yaml::read_yaml(pcodes_yml)
  ),

  tar_target(
    historic_data_rds,
    download_historic_data(sites = site_list_id,
                           start_date = start_date,
                           end_date = end_date,
                           pcodes = pcodes_ugL,
                           statistic_id = "00003",
                           out_file = "out/historic_data.rds"),
    format = "file"
  ),

  tar_target(
    uv_historic_data_rds,
    download_historic_uv_data(sites = site_list_id,
                              start_date = start_date,
                              end_date = end_date,
                              pcodes = pcodes_ugL,
                              out_file = "out/historic_uv_data.rds"),
    format = "file"
  ),

  # WRB sites that switched from ug/L sensors to RFU sensors in 2024
  tar_target(
    pcodes_rfu,
    c("32315")
  ),

  tar_target(
    rfu_sites,
    c("14211720", "14211010", "14181500")
  ),

  tar_target(
    uv_rfu_historic_data_rds,
    download_historic_uv_rfu_data(sites = rfu_sites,
                                  start_date = start_date,
                                  end_date = end_date,
                                  pcodes = pcodes_rfu,
                                  out_file = "out/historic_uv_rfu_data.rds"),
    format = "file"
  ),

  tar_target(
    all_historic_data_csv,
    {
      dv <- read_rds(historic_data_rds) |> mutate(source = "dv")
      uv <- read_rds(uv_historic_data_rds) |> mutate(source = "uv")
      uv_rfu <- read_rds(uv_rfu_historic_data_rds) |> mutate(source = "uv_rfu") |>
        filter(site_no != "14181500")
      site_14181500_rfu <- read_rds(uv_rfu_historic_data_rds) |>
        mutate(source = "uv_rfu") |>
        filter(site_no == "14181500" & dateTime > as.Date("2024-04-24"))
      uv_rfu <- bind_rows(uv_rfu, site_14181500_rfu)
      out_file <- "out/USGS_chl_data.csv"
      out <- bind_rows(dv, uv, uv_rfu) |>
        rename(datetime = dateTime,
               site_id = site_no,
               observation = chl_ug_L) |>
        mutate(variable = "chla",
               site_id = paste0("USGS-", site_id),
               project_id = "usgsrc4cast",
               duration = "P1D") |>
        distinct(site_id, datetime, .keep_all = TRUE) |>
        select(project_id, site_id, datetime,
               duration, variable, observation) |>
        arrange(site_id, datetime)
      write_csv(out, file = out_file)
      return(out_file)
    },
    format = "file"
  ),

  tar_target(
    push_to_targets_s3,
    push_to_s3(
      config = config,
      local_file_name = all_historic_data_csv,
      s3_file_name = config$targets_file_name)
  )

)
