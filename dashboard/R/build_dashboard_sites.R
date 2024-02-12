library(tidyverse)
config <- yaml::read_yaml('challenge_configuration.yaml')
catalog_config <- config$catalog_config

project_sites <- read_csv(catalog_config$site_metadata_url, col_types = cols())
project_sites$site_lat_lon <- lapply(1:nrow(project_sites), function(i) c(project_sites$longitude[i], project_sites$latitude[i]))

iterator_list <- 1:nrow(project_sites)

site_name_coords <- purrr::map(iterator_list, function(i)
  list(
   "type" = "Feature",
   "properties" = list(
     "site_id" = project_sites$site_id[i],
     "Partner" = "USGS",
     "n" =  5 ),
   "geometry" = list(
     "type" = "Point",
     "coordinates" = c(project_sites$longitude[i], project_sites$latitude[i])
  )))


site_info <- list(
  "type" = "FeatureCollection",
  "name" = "usgs",
  "crs" = list(
    "type" = "name",
    "properties" = list(
      "name" = "urn:ogc:def:crs:OGC:1.3:CRS84")
    ),
  "features" = site_name_coords
)

dest <- 'dashboard/'
json <- file.path(dest, "sites.json")


jsonlite::write_json(site_info,
                     json,
                     pretty=TRUE,
                     auto_unbox=TRUE)

#stac4cast::stac_validate(json)



