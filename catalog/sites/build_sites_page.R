library(arrow)
library(dplyr)
library(gsheet)
library(readr)

#source('catalog/R/stac_functions.R')
config <- yaml::read_yaml('challenge_configuration.yaml')
catalog_config <- config$catalog_config

## CREATE table for column descriptions
site_description_create <- data.frame(site_id = 'site identifier',
                                      project_id = 'forecast challenge identifier',
                                      agency_cd = 'organization / agency responsible for site monitoring',
                                      site_no = 'National Water Information System stream gage identifier',
                                      station_nm = 'National Water Information System station long name',
                                      site_tp_cd = 'National Water Information System site type code; https://maps.waterdata.usgs.gov/mapper/help/sitetype.html',
                                      latitude = 'site latitude',
                                      longitude = 'site longitude',
                                      site_url = 'National Water Information System URL for monitoring site',
                                      colocated = '', # TODO: what is colocated?
                                      queryTime = 'timestamp when site metadata was retrieved')

#inventory_theme_df <- arrow::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog/forecasts/project_id={config$project_id}"), endpoint_override = config$endpoint, anonymous = TRUE) #|>

target_url <- config$target_groups$aquatics$targets_file
site_df <- read_csv(config$site_table, show_col_types = FALSE)

# inventory_theme_df <- arrow::open_dataset(arrow::s3_bucket(config$inventory_bucket, endpoint_override = config$endpoint, anonymous = TRUE))
#
# inventory_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog"),
#                                             s3_endpoint = config$endpoint, anonymous=TRUE) |>
#   collect()
#
# theme_models <- inventory_data_df |>
#   distinct(model_id)

targets <- read_csv(target_url)

target_date_range <- targets |> dplyr::summarise(min(datetime),max(datetime))
target_min_date <- as.Date(target_date_range$`min(datetime)`)
target_max_date <- as.Date(target_date_range$`max(datetime)`)

build_description <- paste0("The catalog contains site metadata for the ", config$challenge_long_name)


stac4cast::build_sites(table_schema = site_df,
                       table_description = site_description_create,
                       start_date = target_min_date,
                       end_date = target_max_date,
                       id_value = "sites",
                       description_string = build_description,
                       about_string = catalog_config$about_string,
                       about_title = catalog_config$about_title,
                       theme_title = "Site Metadata",
                       destination_path = config$site_path,
                       #link_items = stac4cast::generate_group_values(group_values = names(config$variable_groups)),
                       link_items = NULL,
                       thumbnail_link = config$site_thumbnail,
                       thumbnail_title = config$site_thumbnail_title)
