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
targets_description_create <- data.frame(project_id = 'unique project identifier',
                                         site_id = 'unique site identifier',
                                         datetime = 'datetime of the observed value (ISO 8601)',
                                         duration = 'temporal duration of target (hourly = PT1H, daily = P1D, etc.); follows ISO 8601 duration convention',
                                         depth_m = 'depth (meters) in water column of observation',
                                         variable = 'observation variable',
                                         observation = 'observed value for variable')

#inventory_theme_df <- arrow::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog/forecasts/project_id={config$project_id}"), endpoint_override = config$endpoint, anonymous = TRUE) #|>

target_url <- config$target_groups$aquatics$targets_file
targets <- read_csv(target_url, show_col_types = FALSE)

# inventory_theme_df <- arrow::open_dataset(arrow::s3_bucket(config$inventory_bucket, endpoint_override = config$endpoint, anonymous = TRUE))
#
# inventory_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog"),
#                                             s3_endpoint = config$endpoint, anonymous=TRUE) |>
#   collect()
#
# theme_models <- inventory_data_df |>
#   distinct(model_id)

target_date_range <- targets |> dplyr::summarise(min(datetime),max(datetime))
target_min_date <- as.Date(target_date_range$`min(datetime)`)
target_max_date <- as.Date(target_date_range$`max(datetime)`)

build_description <- paste0("The targets are observations that can be used to evaluate and build forecasts.  We provide the code to access different targets as an asset.")


stac4cast::build_targets(table_schema = targets,
                         table_description = targets_description_create,
                         start_date = target_min_date,
                         end_date = target_max_date,
                         id_value = "targets",
                         description_string = build_description,
                         about_string = catalog_config$about_string,
                         about_title = catalog_config$about_title,
                         theme_title = "Targets",
                         destination_path = config$targets_path,
                         #link_items = stac4cast::generate_group_values(group_values = names(config$variable_groups)),
                         link_items = NULL,
                         thumbnail_link = config$targets_thumbnail,
                         thumbnail_title = config$targets_thumbnail_title)
