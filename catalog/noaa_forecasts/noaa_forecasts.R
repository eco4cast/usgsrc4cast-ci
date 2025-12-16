library(arrow)
library(dplyr)
library(gsheet)
library(readr)

#source('catalog/R/stac_functions.R')
config <- yaml::read_yaml('../challenge_configuration.yaml')
catalog_config <- config$catalog_config

# file.sources = list.files(c("../stac4cast/R"), full.names=TRUE,
#                           ignore.case=TRUE)
# sapply(file.sources,source,.GlobalEnv)

## CREATE table for column descriptions
noaa_description_create <- data.frame(site_id = 'For forecasts that are not on a spatial grid, use of a site dimension that maps to a more detailed geometry (points, polygons, etc.) is allowable. In general this would be documented in the external metadata (e.g., alook-up table that provides lon and lat)',
                                      prediction = 'predicted value for variable',
                                      variable = 'name of forecasted variable',
                                      height = 'variable height',
                                      horizon = 'number of days in forecast',
                                      parameter = 'ensemble member or distribution parameter',
                                      family = 'For ensembles: “ensemble.” Default value if unspecified for probability distributions: Name of the statistical distribution associated with the reported statistics. The “sample” distribution is synonymous with “ensemble.”For summary statistics: “summary.”',
                                      reference_datetime = 'datetime that the forecast was initiated (horizon = 0)',
                                      forecast_valid = 'date when forecast is valid',
                                      datetime = 'datetime of the forecasted value (ISO 8601)',
                                      longitude = 'forecast site longitude',
                                      latitude = 'forecast site latitude')

noaa_theme_df <- arrow::open_dataset(arrow::s3_bucket(paste0(config$noaa_forecast_bucket,"/stage2/reference_datetime=2024-03-21/site_id=USGS-05553700"), endpoint_override = config$noaa_endpoint, anonymous = TRUE))

#noaa_theme_dates <- arrow::open_dataset(arrow::s3_bucket(paste0(config$noaa_forecast_bucket,"/stage2"), endpoint_override = config$noaa_endpoint, anonymous = TRUE)) |>
#  dplyr::summarise(min(datetime),max(datetime)) |>
#  collect()
#noaa_min_date <- noaa_theme_dates$`min(datetime)`
#noaa_max_date <- noaa_theme_dates$`max(datetime)`

noaa_min_date <- as.Date('2020-01-01')
noaa_max_date <- Sys.Date()

## find group sites
# Prepend ../ because this script runs from catalog/ directory
find_noaa_sites <- read_csv(file.path("..", config$site_table)) |>
  distinct(site_id)

#filter(model_id == model_id, site_id = site_id, reference_datetime = reference_datetime)
# NOTE IF NOT USING FILTER -- THE stac4cast::build_table_columns() NEEDS TO BE UPDATED
#(USE strsplit(forecast_theme_df$ToString(), "\n") INSTEAD OF strsplit(forecast_theme_df[[1]]$ToString(), "\n"))

## identify model ids from bucket -- used in generate model items function
# noaa_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog"),
#                                            s3_endpoint = config$endpoint, anonymous=TRUE) |>
#   collect()

# theme_models <- forecast_data_df |>
#   distinct(model_id)


build_description <- paste0("The catalog contains NOAA forecasts used for the ", config$challenge_long_name,". The forecasts are the raw forecasts that include all ensemble members (if a forecast represents uncertainty using an ensemble). You can access the forecasts at the top level of the dataset where all models, variables, and dates that forecasts were produced (reference_datetime) are available. The code to access the entire dataset is provided as an asset. Given the size of the forecast catalog, it can be time-consuming to access the data at the full dataset level. For quicker access to the forecasts for a site or datetime, we also provide the code to access the data at the site_id and datetime level as an asset for each forecast")

stac4cast::build_forecast_scores(table_schema = noaa_theme_df,
                                 #theme_id = 'Forecasts',
                                 table_description = noaa_description_create,
                                 start_date = noaa_min_date,
                                 end_date = noaa_max_date,
                                 id_value = "noaa-forecasts",
                                 description_string = build_description,
                                 about_string = catalog_config$about_string,
                                 about_title = catalog_config$about_title,
                                 theme_title = "NOAA-Forecasts",
                                 destination_path = catalog_config$noaa_path,
                                 aws_download_path = config$noaa_forecast_bucket,
                                 link_items = stac4cast::generate_group_values(group_values = config$noaa_forecast_groups),
                                 thumbnail_link = catalog_config$noaa_thumbnail,
                                 thumbnail_title = catalog_config$noaa_thumbnail_title,
                                 group_sites = find_noaa_sites$site_id,
                                 model_child = FALSE)


## BUILD VARIABLE GROUPS

for (i in 1:length(config$noaa_forecast_groups)){ ## organize variable groups
  print(config$noaa_forecast_groups[i])


  if (!dir.exists(paste0(catalog_config$noaa_path,config$noaa_forecast_groups[i]))){
    dir.create(paste0(catalog_config$noaa_path,config$noaa_forecast_groups[i]))
  }


  ## CREATE NOAA GROUP JSONS
  group_description <- paste0('This page includes information for NOAA forecasts ', config$noaa_forecast_groups[i])

  stac4cast::build_noaa_forecast(table_schema = noaa_theme_df,
                                 table_description = noaa_description_create,
                                 start_date = noaa_min_date,
                                 end_date = noaa_max_date,
                                 id_value = config$noaa_forecast_groups[i],
                                 description_string = build_description,
                                 about_string = catalog_config$about_string,
                                 about_title = catalog_config$about_title,
                                 theme_title = config$noaa_forecast_groups[i],
                                 destination_path = paste0(catalog_config$noaa_path, config$noaa_forecast_groups[i]),
                                 aws_download_path = config$noaa_forecast_bucket,
                                 link_items = NULL,
                                 thumbnail_link = catalog_config$noaa_thumbnail,
                                 thumbnail_title = catalog_config$noaa_thumbnail_title,
                                 group_sites = find_noaa_sites$field_site_id,
                                 path_item = config$noaa_forecast_group_paths[i])

}
