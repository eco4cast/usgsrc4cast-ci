source("https://raw.githubusercontent.com/eco4cast/neon4cast/ci_upgrade/R/to_hourly.R") # is this branch stable? why use ci_upgrade ?

Sys.setenv("GEFS_VERSION"="v12")

site_list <- readr::read_csv("USGS_site_metadata.csv",
                             show_col_types = FALSE)

config <- yaml::read_yaml("challenge_configuration.yaml")

# should this be updated to a usgsrc4cast-drivers path? or are we keeping all drivers in
#  neon4cast-drivers?
# s3_stage2 <- arrow::s3_bucket("bio230014-bucket01/neon4cast-drivers/noaa/gefs-v12/stage2",
#                               endpoint_override = "sdsc.osn.xsede.org",
#                               access_key= Sys.getenv("OSN_KEY"),
#                               secret_key= Sys.getenv("OSN_SECRET"))
s3_stage2 <- gefs4cast::gefs_s3_dir(product = "stage2",
                                    path = "",
                                    endpoint = config$endpoint,
                                    bucket = config$driver_bucket)

df <- arrow::open_dataset(s3_stage2) |>
  dplyr::distinct(reference_datetime) |>
  dplyr::collect()

#stage1_s3 <- arrow::s3_bucket("bio230014-bucket01/neon4cast-drivers/noaa/gefs-v12/stage1",
#                       endpoint_override = "sdsc.osn.xsede.org",
#                       anonymous = TRUE)


#efi <- duckdbfs::open_dataset("s3://bio230014-bucket01/neon4cast-drivers/noaa/gefs-v12/stage1",
#                    s3_access_key_id="",
#                    s3_endpoint="sdsc.osn.xsede.org")
#df_stage1 <- arrow::open_dataset(stage1_s3) |>
#  dplyr::summarize(max(reference_datetime)) |>
#  dplyr::collect()

curr_date <- Sys.Date()
last_week <- dplyr::tibble(reference_datetime = as.character(seq(curr_date - lubridate::days(7),
                                                                 curr_date - lubridate::days(1),
                                                                 by = "1 day")))

missing_dates <- dplyr::anti_join(last_week, df,
                                  by = "reference_datetime") |>
  dplyr::pull(reference_datetime)

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
                           use_solar_geom = TRUE,
                           psuedo = FALSE) |>
      dplyr::mutate(ensemble = as.numeric(stringr::str_sub(ensemble, start = 4, end = 5)),
                    reference_datetime = lubridate::as_date(reference_datetime)) |>
      dplyr::rename(parameter = ensemble)

    arrow::write_dataset(dataset = hourly_df,
                         path = s3_stage2,
                         partitioning = c("reference_datetime", "site_id"))
  }
}


