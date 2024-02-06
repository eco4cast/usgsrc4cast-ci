## setup
library(gdalcubes)
library(gefs4cast)
# need to source to_hourly.R instead of from neon4cast because there are neon-specific code in neon4cast
source("drivers/to_hourly.R")

Sys.setenv("GEFS_VERSION"="v12")

site_list <- readr::read_csv("USGS_site_metadata.csv",
                             show_col_types = FALSE)

config <- yaml::read_yaml("challenge_configuration.yaml")
driver_bucket <- stringr::word(config$driver_bucket, 1, sep = "/")
driver_path <- stringr::word(config$driver_bucket, 2, -1, sep = "/")

# s3_stage2 <- arrow::s3_bucket("bio230014-bucket01/neon4cast-drivers/noaa/gefs-v12/stage2",
#                               endpoint_override = "sdsc.osn.xsede.org",
#                               access_key= Sys.getenv("OSN_KEY"),
#                               secret_key= Sys.getenv("OSN_SECRET"))
s3_stage2 <- gefs4cast::gefs_s3_dir(product = "stage2",
                                    path = driver_path,
                                    endpoint = config$endpoint,
                                    bucket = driver_bucket)

# if there aren't any data (i.e., this is the first time we're creating this dataset),
#  then skip the distinct(reference_datetime) filter
df <- arrow::open_dataset(s3_stage2)
if(length(df$files) > 0){
  df <- arrow::open_dataset(s3_stage2) |>
    dplyr::distinct(reference_datetime) |>
    dplyr::collect()
}

curr_date <- Sys.Date()
last_week <- dplyr::tibble(reference_datetime = as.character(seq(curr_date - lubridate::days(7),
                                                                 curr_date - lubridate::days(1),
                                                                 by = "1 day")))

if(length(df$files) > 0){
  missing_dates <- dplyr::anti_join(last_week, df,
                                    by = "reference_datetime") |>
    dplyr::pull(reference_datetime)
}else{
  missing_dates <- dplyr::pull(last_week, reference_datetime)
}


if(length(missing_dates) > 0){
  for(i in 1:length(missing_dates)){

    print(missing_dates[i])

    # bucket <- paste0("bio230014-bucket01/neon4cast-drivers/noaa/gefs-v12/stage1/reference_datetime=",
    #                  missing_dates[i])
    bucket <- glue::glue("{config$driver_bucket}/gefs-v12/stage1/reference_datetime={missing_dates[i]}")

    s3_stage1 <- arrow::s3_bucket(bucket = bucket,
                                  endpoint_override = config$endpoint,
                                  anonymous = TRUE)

    site_df <- arrow::open_dataset(s3_stage1) |>
      dplyr::filter(variable %in% c("PRES","TMP","RH","UGRD","VGRD","APCP","DSWRF","DLWRF")) |>
      dplyr::filter(site_id %in% site_list$site_id) |>
      dplyr::collect() |>
      dplyr::mutate(reference_datetime = missing_dates[i])

    hourly_df <- to_hourly(site_df,
                           site_list = dplyr::select(site_list, site_id, latitude, longitude),
                           use_solar_geom = TRUE,
                           pseudo = FALSE) |>
      dplyr::mutate(ensemble = as.numeric(stringr::str_sub(ensemble, start = 4, end = 5)),
                    reference_datetime = lubridate::as_date(reference_datetime)) |>
      dplyr::rename(parameter = ensemble)

    arrow::write_dataset(dataset = hourly_df,
                         path = s3_stage2,
                         partitioning = c("reference_datetime", "site_id"))
  }
}


