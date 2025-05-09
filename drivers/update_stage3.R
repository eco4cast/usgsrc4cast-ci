library(gdalcubes)
library(gefs4cast)
source("R/eco4cast-helpers/to_hourly.R")

site_df <- readr::read_csv(paste0("https://github.com/eco4cast/usgsrc4cast-ci/",
                                  "raw/main/USGS_site_metadata.csv"),
                           show_col_types = FALSE)
site_list <- site_df |>
  dplyr::pull(site_id)

Sys.setenv("GEFS_VERSION"="v12")

config <- yaml::read_yaml("challenge_configuration.yaml")
driver_bucket <- stringr::word(config$driver_bucket, 1, sep = "/")
driver_path <- stringr::word(config$driver_bucket, 2, -1, sep = "/")


purrr::map(site_list, function(curr_site_id){

  print(curr_site_id)

  s3_stage3 <- gefs4cast::gefs_s3_dir(product = "stage3",
                                      path = driver_path,
                                      endpoint = config$endpoint,
                                      bucket = driver_bucket)

  # case for if this is the first time creating stage3 drivers
  stage3_dataset <- arrow::open_dataset(s3_stage3)
  if(length(stage3_dataset$files) > 0){
    stage3_df <- stage3_dataset |>
      dplyr::filter(site_id == curr_site_id) |>
      dplyr::collect()
    if(nrow(stage3_df) == 0){
      max_date <- NA
    }else{
      max_date <- stage3_df |>
        dplyr::summarise(max = as.character(lubridate::as_date(max(datetime)))) |>
        dplyr::pull(max)
    }

  }else{
    max_date <- NA
  }

  s3_pseudo <- gefs4cast::gefs_s3_dir(product = "pseudo",
                                      path = driver_path,
                                      endpoint = config$endpoint,
                                      bucket = driver_bucket)

  if(length(stage3_dataset$files) > 0 & nrow(stage3_df) > 0){
    cut_off <- as.character(lubridate::as_date(max_date) - lubridate::days(3))
  }

  if(length(stage3_dataset$files) > 0 & nrow(stage3_df) > 0){
    pseudo_df <- arrow::open_dataset(s3_pseudo) |>
      dplyr::filter(variable %in% c("PRES","TMP","RH","UGRD","VGRD","APCP","DSWRF","DLWRF")) |>
      dplyr::filter(site_id == curr_site_id,
                    reference_datetime >= cut_off) |>
      dplyr::collect()
  }else{
    pseudo_df <- arrow::open_dataset(s3_pseudo) |>
      dplyr::filter(variable %in% c("PRES","TMP","RH","UGRD","VGRD","APCP","DSWRF","DLWRF")) |>
      dplyr::filter(site_id == curr_site_id) |>
      dplyr::collect()
  }


  if(nrow(pseudo_df) > 0){

    df2 <- pseudo_df |>
      to_hourly(site_list = dplyr::select(site_df, site_id, latitude, longitude),
                use_solar_geom = TRUE,
                pseudo = TRUE) |>
      dplyr::mutate(ensemble = as.numeric(stringr::str_sub(ensemble, start = 4, end = 5))) |>
      dplyr::rename(parameter = ensemble)

    if(length(stage3_dataset$files) > 0 & nrow(stage3_df) > 0){
      stage3_df_update <- stage3_df |>
        dplyr::filter(datetime < min(df2$datetime))

      df2 |>
        dplyr::bind_rows(stage3_df_update) |>
        dplyr::arrange(variable, datetime, parameter) |>
        arrow::write_dataset(path = s3_stage3, partitioning = "site_id")
    }else{
      df2 |>
        dplyr::arrange(variable, datetime, parameter) |>
        arrow::write_dataset(path = s3_stage3, partitioning = "site_id")
    }

  }
})
