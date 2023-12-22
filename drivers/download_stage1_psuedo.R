## setup
library(gdalcubes)
library(gefs4cast)

gdalcubes::gdalcubes_options(parallel=2*parallel::detectCores())
#gdalcubes::gdalcubes_options(parallel=TRUE)

config <- yaml::read_yaml("challenge_configuration.yaml")

sites <- readr::read_csv(paste0("https://github.com/eco4cast/usgsrc4cast-ci/",
                                "raw/prod/USGS_site_metadata.csv"),
                         col_select = c("site_id", "latitude", "longitude"))

Sys.setenv("GEFS_VERSION"="v12")
dates <- seq(as.Date("2020-09-24"), Sys.Date()-1, by=1)
dates_pseudo <- seq(as.Date("2020-09-24"), Sys.Date(), by=1)

message("GEFS v12 stage1-stats")
bench::bench_time({ # thelio
  s3 <- gefs4cast::gefs_s3_dir(product = "stage1-stats",
                               path = "", # should this path be more specific? the noaa bucket in the config is "drivers/noaa/gefs-v12-reprocess/"
                               endpoint = config$endpoint,
                               bucket = config$driver_bucket)
  have_dates <- gsub("reference_datetime=", "", s3$ls())
  missing_dates <- dates[!(as.character(dates) %in% have_dates)]
  gefs4cast::gefs_to_parquet(dates = missing_dates,
                             ensemble = c("geavg", "gespr"),
                             path = s3,
                             sites = sites) # should partitioning also include the project_id ??
})

message("GEFS v12 pseudo")
bench::bench_time({ #32xlarge
  s3 <- gefs4cast::gefs_s3_dir(product = "pseudo",
                               path = "", # same questions as above ^
                               endpoint = config$endpoint,
                               bucket = config$driver_bucket)
  have_dates <- gsub("reference_datetime=", "", s3$ls())
  missing_dates <- dates_pseudo[!(as.character(dates_pseudo) %in% have_dates)]
  gefs4cast:::gefs_pseudo_measures(dates = missing_dates,
                                   path = s3,
                                   sites = sites)
})

message("GEFS v12 stage1")
bench::bench_time({ # cirrus ~ 6days for full set
  s3 <- gefs4cast::gefs_s3_dir(product = "stage1",
                               path = "",
                               endpoint = config$endpoint,
                               bucket = config$driver_bucket)
  have_dates <- gsub("reference_datetime=", "", s3$ls())
  missing_dates <- dates[!(as.character(dates) %in% have_dates)]
  gefs4cast::gefs_to_parquet(dates = missing_dates,
                             path = s3,
                             sites = sites)
})
