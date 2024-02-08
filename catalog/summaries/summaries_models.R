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
summaries_description_create <- data.frame(reference_datetime = 'datetime that the forecast was initiated (horizon = 0)',
                                           site_id = 'For forecasts that are not on a spatial grid, use of a site dimension that maps to a more detailed geometry (points, polygons, etc.) is allowable. In general this would be documented in the external metadata (e.g., alook-up table that provides lon and lat)',
                                           datetime = 'datetime of the forecasted value (ISO 8601)',
                                           family = 'For ensembles: “ensemble.” Default value if unspecified for probability distributions: Name of the statistical distribution associated with the reported statistics. The “sample” distribution is synonymous with “ensemble.”For summary statistics: “summary.”',
                                           pub_datetime = 'datetime that forecast was submitted',
                                           depth_m = 'depth (meters) in water column of prediction',
                                           mean = 'mean forecast prediction',
                                           median = 'median forecast prediction',
                                           sd = 'standard deviation forecasts',
                                           quantile97.5 = 'upper 97.5 percentile value of forecast',
                                           quantile02.5 = 'upper 2.5 percentile value of forecast',
                                           quantile90 = 'upper 90 percentile value of forecast',
                                           quantile10 = 'upper 10 percentile value of forecast',
                                           project_id = 'unique identifier for the forecast project',
                                           duration = 'temporal duration of forecast (hourly, daily, etc.); follows ISO 8601 duration convention',
                                           variable = 'name of forecasted variable',
                                           model_id = 'unique model identifier',
                                           reference_date = 'date that the forecast was initiated')


summaries_theme_df <- arrow::open_dataset(arrow::s3_bucket(config$summaries_bucket, endpoint_override = config$endpoint, anonymous = TRUE)) #|>
#filter(model_id == model_id, site_id = site_id, reference_datetime = reference_datetime)
# NOTE IF NOT USING FILTER -- THE stac4cast::build_table_columns() NEEDS TO BE UPDATED
#(USE strsplit(summaries_theme_df$ToString(), "\n") INSTEAD OF strsplit(summaries_theme_df[[1]]$ToString(), "\n"))

## identify model ids from bucket -- used in generate model items function

summaries_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog/forecasts"),
                                            s3_endpoint = config$endpoint, anonymous=TRUE) |>
  collect() |>
  dplyr::filter(project_id == config$project_id)

theme_models <- summaries_data_df |>
  distinct(model_id)

forecast_date_range <- summaries_data_df |> dplyr::summarise(min(date),max(date))
forecast_min_date <- forecast_date_range$`min(date)`
forecast_max_date <- forecast_date_range$`max(date)`

build_description <- paste0("Summaries are the forecasts statistics of the raw forecasts (i.e., mean, median, confidence intervals). You can access the summaries at the top level of the dataset where all models, variables, and dates that forecasts were produced (reference_datetime) are available. The code to access the entire dataset is provided as an asset. Given the size of the forecast catalog, it can be time-consuming to access the data at the full dataset level. For quicker access to the forecasts for a particular model (model_id), we also provide the code to access the data at the model_id level as an asset for each model.")

stac4cast::build_forecast_scores(table_schema = summaries_theme_df,
                                 #theme_id = 'Forecasts',
                                 table_description = summaries_description_create,
                                 start_date = forecast_min_date,
                                 end_date = forecast_max_date,
                                 id_value = "summaries",
                                 description_string = build_description,
                                 about_string = catalog_config$about_string,
                                 about_title = catalog_config$about_title,
                                 theme_title = "Forecast Summaries",
                                 destination_path = catalog_config$summaries_path,
                                 aws_download_path = catalog_config$summaries_download_path,
                                 link_items = stac4cast::generate_group_values(group_values = names(config$variable_groups)),
                                 thumbnail_link = catalog_config$summaries_thumbnail,
                                 thumbnail_title = catalog_config$summaries_thumbnail_title,
                                 model_child = TRUE)

## create separate JSON for model landing page

stac4cast::build_group_variables(table_schema = summaries_theme_df,
                                 table_description = summaries_description_create,
                                 start_date = forecast_min_date,
                                 end_date = forecast_max_date,
                                 id_value = "models",
                                 description_string = build_description,
                                 about_string = catalog_config$about_string,
                                 about_title = catalog_config$about_title,
                                 dashboard_string = catalog_config$dashboard_url,
                                 dashboard_title = catalog_config$dashboard_title,
                                 theme_title = "Models",
                                 destination_path = paste0(catalog_config$summaries_path,"models"),
                                 aws_download_path = catalog_config$summaries_download_path,
                                 group_var_items = stac4cast::generate_model_items(model_list = theme_models$model_id),
                                 thumbnail_link = 'pending',
                                 thumbnail_title = 'pending',
                                 group_var_vector = NULL,
                                 group_sites = NULL)

## CREATE MODELS
variable_gsheet <- gsheet2tbl(config$target_metadata_gsheet)

## READ IN MODEL METADATA
# googlesheets4::gs4_deauth()
#
# registered_model_id <- googlesheets4::read_sheet(config$model_metadata_gsheet)

# read in model metadata and filter for the relevant project
registered_model_id <- gsheet2tbl(config$model_metadata_gsheet) |>
  filter(`What forecasting challenge are you registering for?` == config$project_id)

forecast_sites <- c()

## LOOP OVER MODEL IDS AND CREATE JSONS
for (m in theme_models$model_id){

  # make model items directory
  if (!dir.exists(paste0(catalog_config$summaries_path,"models/model_items"))){
    dir.create(paste0(catalog_config$summaries_path,"models/model_items"))
  }

  print(m)
  model_date_range <- summaries_data_df |> filter(model_id == m) |> dplyr::summarise(min(date),max(date))
  model_min_date <- model_date_range$`min(date)`
  model_max_date <- model_date_range$`max(date)`

  model_var_duration_df <- summaries_data_df |> filter(model_id == m) |> distinct(variable,duration) |>
    mutate(duration_name = ifelse(duration == 'P1D', 'Daily', duration)) |>
    mutate(duration_name = ifelse(duration == 'PT1H', 'Hourly', duration_name)) |>
    mutate(duration_name = ifelse(duration == 'PT30M', '30min', duration_name)) |>
    mutate(duration_name = ifelse(duration == 'P1W', 'Weekly', duration_name))

  model_var_full_name <- model_var_duration_df |>
    left_join((variable_gsheet |>
                 select(variable = `"official" targets name`, full_name = `Variable name`) |>
                 distinct(variable, .keep_all = TRUE)), by = c('variable'))

  model_sites <- summaries_data_df |> filter(model_id == m) |> distinct(site_id)

  model_vars <- summaries_data_df |> filter(model_id == m) |> distinct(variable) |> left_join(model_var_full_name, by = 'variable')
  model_vars$var_duration_name <- paste0(model_vars$duration_name, " ", model_vars$full_name)

  forecast_sites <- append(forecast_sites,  stac4cast::get_site_coords(site_metadata = catalog_config$site_metadata_url,
                                                                       sites = model_sites$site_id))

  idx = which(registered_model_id$model_id == m)

  stac4cast::build_model(model_id = m,
                         team_name = registered_model_id$`Long name of the model (can include spaces)`[idx],
                         model_description = registered_model_id[idx,"Describe your modeling approach in your own words."][[1]],
                         start_date = model_min_date,
                         end_date = model_max_date,
                         var_values = model_vars$var_duration_name,
                         duration_names = model_var_duration_df$duration,
                         site_values = model_sites$site_id,
                         site_table = catalog_config$site_metadata_url,
                         model_documentation = registered_model_id,
                         destination_path = paste0(catalog_config$summaries_path,"models/model_items"),
                         aws_download_path = config$summaries_bucket, # CHANGE THIS BUCKET NAME
                         collection_name = 'forecasts',
                         thumbnail_image_name = NULL,
                         table_schema = summaries_theme_df,
                         table_description = summaries_description_create,
                         full_var_df = model_vars,
                         code_web_link = registered_model_id$`Web link to model code`[idx])
  #code_web_link = 'pending')
}


## BUILD VARIABLE GROUPS

for (i in 1:length(config$variable_groups)){ ## organize variable groups
  print(names(config$variable_groups)[i])

  # check data and skip if no data found
  var_group_data_check <- summaries_data_df |>
    filter(variable %in% config$variable_groups[[i]]$variable)

  if (nrow(var_group_data_check) == 0){
    print('No data available for group')
    next
  }

  ## REMOVE STALE OR UNUSED DIRECTORIES
  current_var_path <- paste0(catalog_config$summaries_path,names(config$variable_groups[i]))
  current_var_dirs <- list.dirs(current_var_path, recursive = FALSE, full.names = TRUE)
  unlink(current_var_dirs, recursive = TRUE)

  if (!dir.exists(paste0(catalog_config$summaries_path,names(config$variable_groups[i])))){
    dir.create(paste0(catalog_config$summaries_path,names(config$variable_groups[i])))
  }


  for(j in 1:length(config$variable_groups[[i]]$variable)){ # FOR EACH VARIABLE WITHIN A MODEL GROUP

    ## restructure variable names
    var_values <- config$variable_groups[[i]]$variable
    var_name <- config$variable_groups[[i]]$variable[j]
    print(var_name)

    # check data and skip if no data found
    var_data_check <- summaries_data_df |>
      filter(variable == var_name)

    if (nrow(var_data_check) == 0){
      print('No data available for variable')
      next
    }


    duration_name <- config$variable_groups[[i]]$duration[j]

    # # match variable with full name in gsheet
    # #var_name_full <- variable_gsheet[which(variable_gsheet$`"official" targets name` == var_values),1][[1]]
    # var_name_full <- variable_gsheet[which(variable_gsheet$`"official" targets name` %in% var_values),1][[1]]

    # match variable with full name in gsheet
    var_gsheet_arrange <- variable_gsheet |>
      arrange(duration)

    var_name_full <- var_gsheet_arrange[which(var_gsheet_arrange$`"official" targets name` %in% var_values),1][[1]]


    ## create new vector to store duration names
    duration_values <- config$variable_groups[[i]]$duration
    duration_values[which(duration_values == 'P1D')] <- 'Daily'
    duration_values[which(duration_values == 'PT1H')] <- 'Hourly'
    duration_values[which(duration_values == 'PT30M')] <- '30min'
    duration_values[which(duration_values == 'P1W')] <- 'Weekly'

    #var_name_combined_list <- paste0(var_values, '_',duration_values)
    #var_name_combined_list <- paste0(duration_values,' ',var_name_full)
    var_name_combined_list <- paste0(duration_values,'_',var_name_full)

    if (length(unique(var_name_combined_list)) == 1){
      var_name_combined_list <- unique(var_name_combined_list)
    }


    ## CREATE VARIABLE GROUP JSONS
    group_description <- paste0('This page includes variables for the ',names(config$variable_groups[i]),' group.')

    ## find group sites
    find_group_sites <- summaries_data_df |>
      filter(variable %in% var_values) |>
      distinct(site_id)

    stac4cast::build_group_variables(table_schema = summaries_theme_df,
                                     #theme_id = names(config$variable_groups[i]),
                                     table_description = summaries_description_create,
                                     start_date = forecast_min_date,
                                     end_date = forecast_max_date,
                                     id_value = names(config$variable_groups[i]),
                                     description_string = group_description,
                                     about_string = catalog_config$about_string,
                                     about_title = catalog_config$about_title,
                                     dashboard_string = catalog_config$dashboard_url,
                                     dashboard_title = catalog_config$dashboard_title,
                                     theme_title = names(config$variable_groups[i]),
                                     destination_path = paste0(catalog_config$summaries_path,names(config$variable_groups[i])),
                                     aws_download_path = catalog_config$summaries_download_path,
                                     group_var_items = stac4cast::generate_group_variable_items(variables = var_name_combined_list),
                                     thumbnail_link = config$variable_groups[[i]]$thumbnail_link,
                                     thumbnail_title = config$variable_groups[[i]]$thumbnail_title,
                                     group_var_vector = unique(var_values),
                                     group_sites = find_group_sites$site_id)

    if (!dir.exists(paste0(catalog_config$summaries_path,names(config$variable_groups)[i],'/',var_name_combined_list[j]))){
      dir.create(paste0(catalog_config$summaries_path,names(config$variable_groups)[i],'/',var_name_combined_list[j]))
    }

    # var_data <- summaries_data_df |>
    #   filter(variable == var_name,
    #          duration == duration_name)
    var_data <- summaries_data_df |>
      filter(variable == var_name)
    #duration == duration_name)

    var_date_range <- var_data |> dplyr::summarise(min(date),max(date))
    var_min_date <- var_date_range$`min(date)`
    var_max_date <- var_date_range$`max(date)`

    var_models <- var_data |> distinct(model_id)

    find_var_sites <- summaries_data_df |>
      filter(variable == var_name) |>
      distinct(site_id)

    var_description <- paste0('This page includes all models for the ',var_name_combined_list[j],' variable.')

    stac4cast::build_group_variables(table_schema = summaries_theme_df,
                                     table_description = summaries_description_create,
                                     start_date = var_min_date,
                                     end_date = var_max_date,
                                     id_value = var_name_combined_list[j],
                                     description_string = var_description,
                                     about_string = catalog_config$about_string,
                                     about_title = catalog_config$about_title,
                                     dashboard_string = catalog_config$dashboard_url,
                                     dashboard_title = catalog_config$dashboard_title,
                                     theme_title = var_name_combined_list[j],
                                     destination_path = file.path(catalog_config$summaries_path,names(config$variable_groups)[i],var_name_combined_list[j]),
                                     aws_download_path = var_data$path[1],
                                     group_var_items = stac4cast::generate_variable_model_items(model_list = var_models$model_id),
                                     thumbnail_link = 'pending',
                                     thumbnail_title = 'pending',
                                     group_var_vector = NULL,
                                     group_sites = find_var_sites$site_id)

  }

}
