## setup
library(minioclient)
library(gdalcubes)
library(gefs4cast)
source("drivers/to_hourly.R")

config <- yaml::read_yaml("challenge_configuration.yaml")
driver_bucket <- stringr::word(config$driver_bucket, 1, sep = "/")
driver_path <- stringr::word(config$driver_bucket, 2, -1, sep = "/")

Sys.setenv("GEFS_VERSION"="v12")

#install_mc()
mc_alias_set("osn", "sdsc.osn.xsede.org", "", "")

mc_mirror(glue::glue("osn/{driver_bucket}/{driver_path}/gefs-v12/pseudo"), "pseudo")

df <- arrow::open_dataset("pseudo") |>
  dplyr::filter(variable %in% c("PRES","TMP","RH","UGRD","VGRD","APCP","DSWRF","DLWRF"))


site_list <- readr::read_csv(paste0("https://github.com/eco4cast/usgsrc4cast-ci/",
                                    "raw/prod/USGS_site_metadata.csv"),
                             show_col_types = FALSE)


s3_stage3 <- gefs4cast::gefs_s3_dir(product = "stage3",
                                    path = driver_path,
                                    endpoint = config$endpoint,
                                    bucket = driver_bucket)

future::plan("future::multisession", workers = 8)

furrr::future_walk(dplyr::pull(site_list, site_id), function(curr_site_id){

  df <- arrow::open_dataset("pseudo") |>
    dplyr::filter(variable %in% c("PRES","TMP","RH","UGRD","VGRD","APCP","DSWRF","DLWRF")) |>
    dplyr::filter(site_id == curr_site_id) |>
    dplyr::collect()

  s3_stage3 <- gefs4cast::gefs_s3_dir(product = "stage3",
                                      path = driver_path,
                                      endpoint = config$endpoint,
                                      bucket = driver_bucket)

  print(curr_site_id)
  df |>
    to_hourly(site_list = dplyr::select(site_list, site_id, latitude, longitude),
              use_solar_geom = TRUE,
              psuedo = TRUE) |>
    dplyr::mutate(ensemble = as.numeric(stringr::str_sub(ensemble, start = 4, end = 5))) |>
    dplyr::rename(parameter = ensemble) |>
    arrow::write_dataset(path = s3, partitioning = "site_id")
})
