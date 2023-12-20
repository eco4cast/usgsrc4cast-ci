## setup
library(gdalcubes)
library(gefs4cast)

gdalcubes::gdalcubes_options(parallel=2*parallel::detectCores())
#gdalcubes::gdalcubes_options(parallel=TRUE)

sites <- readr::read_csv(paste0("https://github.com/eco4cast/usgsrc4cast-ci/",
                                "raw/main/USGS_site_metadata.csv"),
                         col_select = c("site_id", "latitude", "longitude"))

Sys.setenv("GEFS_VERSION"="v12")
dates <- seq(as.Date("2020-09-24"), Sys.Date()-1, by=1)
dates_pseudo <- seq(as.Date("2020-09-24"), Sys.Date(), by=1)

message("GEFS v12 stage1-stats")
bench::bench_time({ # thelio
  s3 <- gefs_s3_dir("stage1-stats")
  have_dates <- gsub("reference_datetime=", "", s3$ls())
  missing_dates <- dates[!(as.character(dates) %in% have_dates)]
  gefs_to_parquet(missing_dates,
                  ensemble=c("geavg", "gespr"),
                  path = s3,
                  sites = sites)
})

message("GEFS v12 pseudo")
bench::bench_time({ #32xlarge
  s3 <- gefs_s3_dir("pseudo")
  have_dates <- gsub("reference_datetime=", "", s3$ls())
  missing_dates <- dates_pseudo[!(as.character(dates_pseudo) %in% have_dates)]
  gefs4cast:::gefs_pseudo_measures(missing_dates,  path = s3, sites = sites)
})

message("GEFS v12 stage1")
bench::bench_time({ # cirrus ~ 6days for full set
  s3 <- gefs_s3_dir("stage1")
  have_dates <- gsub("reference_datetime=", "", s3$ls())
  missing_dates <- dates[!(as.character(dates) %in% have_dates)]
  gefs_to_parquet(missing_dates, path = s3, sites = sites)
})
