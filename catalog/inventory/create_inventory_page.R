library(arrow)
library(dplyr)
library(gsheet)
library(readr)

#source('catalog/R/stac_functions.R')
config <- yaml::read_yaml('challenge_configuration.yaml')
catalog_config <- config$catalog_config

# file.sources = list.files(c("../stac4cast/R"), full.names=TRUE,
#                           ignore.case=TRUE)
# sapply(file.sources,source,.GlobalEnv)

## CREATE table for column descriptions
inventory_description_create <- data.frame(duration = 'sample duration code for variable',
                                           model_id = 'unique model identifier',
                                           site_id = 'unique site identifier',
                                           reference_date = 'date that the forecast was initiated (horizon = 0)',
                                           variable = 'forecast variable',
                                           date = 'date of the predicted value',
                                           project_id = 'unique project identifier',
                                           path = 'storage path for forecast data',
                                           endpoint = 'storage location for forecast data')

#inventory_theme_df <- arrow::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog/forecasts/project_id={config$project_id}"), endpoint_override = config$endpoint, anonymous = TRUE) #|>

interest_variables <- unlist(sapply(1:length(config$variable_groups), function(i) {config$variable_groups[[i]]$variable}))

inventory_theme_df <- arrow::open_dataset(arrow::s3_bucket(config$inventory_bucket, endpoint_override = config$endpoint, anonymous = TRUE))

# inventory_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog"),
#                                             s3_endpoint = config$endpoint, anonymous=TRUE) |>
# inventory_data_df <- arrow::open_dataset(arrow::s3_bucket(config$inventory_bucket, endpoint_override = config$endpoint, anonymous = TRUE)) |>
#   collect()

inventory_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog/forecasts"),
                                            s3_endpoint = config$endpoint, anonymous=TRUE) |>
  filter(variable %in% interest_variables) |>
  collect()

theme_models <- inventory_data_df |>
  distinct(model_id)

inventory_date_range <- inventory_data_df |> dplyr::summarise(min(date),max(date))
inventory_min_date <- inventory_date_range$`min(date)`
inventory_max_date <- inventory_date_range$`max(date)`

build_description <- paste0("The catalog contains forecasts for the ", config$challenge_long_name,". The forecasts are the raw forecasts that include all ensemble members (if a forecast represents uncertainty using an ensemble).  Due to the size of the raw forecasts, we recommend accessing the scores (summaries of the forecasts) to analyze forecasts (unless you need the individual ensemble members). You can access the forecasts at the top level of the dataset where all models, variables, and dates that forecasts were produced (reference_datetime) are available. The code to access the entire dataset is provided as an asset. Given the size of the forecast catalog, it can be time-consuming to access the data at the full dataset level. For quicker access to the forecasts for a particular model (model_id), we also provide the code to access the data at the model_id level as an asset for each model.")


stac4cast::build_inventory(table_schema = inventory_theme_df,
                           table_description = inventory_description_create,
                           start_date = inventory_min_date,
                           end_date = inventory_max_date,
                           id_value = "inventory",
                           description_string = build_description,
                           about_string = catalog_config$about_string,
                           about_title = catalog_config$about_title,
                           theme_title = "Inventory",
                           destination_path = catalog_config$inventory_path,
                           aws_download_path = config$inventory_bucket,
                           #link_items = stac4cast::generate_group_values(group_values = names(config$variable_groups)),
                           link_items = NULL,
                           thumbnail_link = catalog_config$inventory_thumbnail,
                           thumbnail_title = catalog_config$inventory_thumbnail_title,
                           project_identifier = config$project_id)
