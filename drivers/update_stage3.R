library(gdalcubes)
library(gefs4cast)
source("drivers/to_hourly.R")

site_list <- readr::read_csv(paste0("https://github.com/eco4cast/usgsrc4cast-ci/",
                                    "raw/prod/USGS_site_metadata.csv"),
                             show_col_types = FALSE)

Sys.setenv("GEFS_VERSION"="v12")

config <- yaml::read_yaml("challenge_configuration.yaml")
driver_bucket <- stringr::word(config$driver_bucket, 1, sep = "/")
driver_path <- stringr::word(config$driver_bucket, 2, -1, sep = "/")

future::plan("future::multisession", workers = 8)

furrr::future_walk(dplyr::pull(site_list, site_id), function(curr_site_id){

  print(curr_site_id)

  s3_stage3 <- gefs4cast::gefs_s3_dir(product = "stage3",
                                      path = driver_path,
                                      endpoint = config$endpoint,
                                      bucket = driver_bucket)

  stage3_df <- arrow::open_dataset(s3_stage3) |>
    dplyr::filter(site_id == curr_site_id) |>
    dplyr::collect()

  max_date <- stage3_df |>
    dplyr::summarise(max = as.character(lubridate::as_date(max(datetime)))) |>
    dplyr::pull(max)

  s3_pseudo <- gefs4cast::gefs_s3_dir(product = "pseudo",
                                      path = driver_path,
                                      endpoint = config$endpoint,
                                      bucket = driver_bucket)

  vars <- names(stage3_df)

  cut_off <- as.character(lubridate::as_date(max_date) - lubridate::days(3))

  pseudo_df <- arrow::open_dataset(s3_pseudo) |>
    dplyr::filter(variable %in% c("PRES","TMP","RH","UGRD","VGRD","APCP","DSWRF","DLWRF")) |>
    dplyr::filter(site_id == curr_site_id,
                  reference_datetime >= cut_off) |>
    dplyr::collect()

  if(nrow(psuedo_df) > 0){

    df2 <- psuedo_df |>
      to_hourly(site_list = dplyr::select(site_list, site_id, latitude, longitude),
                use_solar_geom = TRUE,
                psuedo = TRUE) |>
      dplyr::mutate(ensemble = as.numeric(stringr::str_sub(ensemble, start = 4, end = 5))) |>
      dplyr::rename(parameter = ensemble)

    stage3_df_update <- stage3_df |>
      dplyr::filter(datetime < min(df2$datetime))

    df2 |>
      dplyr::bind_rows(stage3_df_update) |>
      dplyr::arrange(variable, datetime, parameter) |>
      arrow::write_dataset(path = s3_stage3, partitioning = "site_id")
  }
})
