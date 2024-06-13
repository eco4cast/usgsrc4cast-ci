library(arrow)
library(dplyr)
library(gsheet)
library(readr)

#source('catalog/R/stac_functions.R')
config <- yaml::read_yaml('challenge_configuration.yaml')
catalog_config <- config$catalog_config

## CREATE table for column descriptions
scores_description_create <- data.frame(reference_datetime ='datetime that the forecast was initiated (horizon = 0)',
                                 site_id = 'For forecasts that are not on a spatial grid, use of a site dimension that maps to a more detailed geometry (points, polygons, etc.) is allowable. In general this would be documented in the external metadata (e.g., alook-up table that provides lon and lat); however in netCDF this could be handled by the CF Discrete Sampling Geometry data model.',
                                 datetime = 'datetime of the forecasted value (ISO 8601)',
                                 family = 'For ensembles: “ensemble.” Default value if unspecified For probability distributions: Name of the statistical distribution associated with the reported statistics. The “sample” distribution is synonymous with “ensemble.” For summary statistics: “summary.”If this dimension does not vary, it is permissible to specify family as a variable attribute if the file format being used supports this (e.g.,netCDF).',
                                 variable = 'name of forecasted variable',
                                 observation = 'observed value for variable',
                                 crps = 'crps forecast score',
                                 logs = 'logs forecast score',
                                 mean = 'mean forecast prediction',
                                 median = 'median forecast prediction',
                                 sd = 'standard deviation forecasts',
                                 quantile97.5 = 'upper 97.5 percentile value of forecast',
                                 quantile02.5 = 'upper 2.5 percentile value of forecast',
                                 quantile90 = 'upper 90 percentile value of forecast',
                                 quantile10 = 'upper 10 percentile value of forecast',
                                 duration = 'temporal duration of forecast (hourly = PT1H, daily = P1D, etc.); follows ISO 8601 duration convention',
                                 depth_m = 'depth (meters) in water column of prediction',
                                 model_id = 'unique model identifier',
                                 date = 'ISO 8601 (ISO 2019) date of the predicted value; follows CF convention http://cfconventions.org/cf-conventions/cf-conventions.html#time-coordinate. This variable was called time before v0.5of the EFI convention. For time-integrated variables (e.g., cumulative net primary productivity), one should specify the start_datetime and end_datetime as two variables, instead of the single datetime. If this is not provided the datetime is assumed to be the MIDPOINT of the integration period.',
                                 pub_datetime = 'datetime that forecast was submitted',
                                 project_id = 'unique project identifier')


## just read in example forecast to extract schema information -- ask about better ways of doing this
# theme <- 'daily'
# reference_datetime <- '2023-09-01'
# site_id <- 'fcre'
# model_id <- 'climatology'

print('FIND SCORES TABLE SCHEMA')
scores_theme_df <- arrow::open_dataset(arrow::s3_bucket(config$scores_bucket, endpoint_override = config$endpoint, anonymous = TRUE)) #|>
  #filter(model_id == model_id, site_id = site_id, reference_datetime = reference_datetime)

## identify model ids from bucket -- used in generate model items function
# scores_data_df <- duckdbfs::open_dataset(glue::glue("s3://{config$inventory_bucket}/catalog/forecasts/project_id={config$project_id}"),
#                                   s3_endpoint = config$endpoint, anonymous=TRUE) |>
#   collect()

print('FIND INVENTORY BUCKET')
scores_s3 <- arrow::s3_bucket(glue::glue("{config$inventory_bucket}/catalog/scores/project_id={config$project_id}"),
                                endpoint_override = "sdsc.osn.xsede.org",
                                anonymous=TRUE)

print('OPEN INVENTORY BUCKET')
scores_data_df <- arrow::open_dataset(scores_s3) |>
  filter(project_id == config$project_id) |>
  collect()

theme_models <- scores_data_df |>
  distinct(model_id)

scores_date_range <- scores_data_df |> dplyr::summarise(min(date),max(date))
scores_min_date <- scores_date_range$`min(date)`
scores_max_date <- scores_date_range$`max(date)`

build_description <- paste0("The catalog contains scores for the ", config$challenge_long_name,". The scores are summaries of the forecasts (i.e., mean, median, confidence intervals), matched observations (if available), and scores (metrics of how well the model distribution compares to observations). You can access the scores at the top level of the dataset where all models, variables, and dates that forecasts were produced (reference_datetime) are available. The code to access the entire dataset is provided as an asset. Given the size of the scores catalog, it can be time-consuming to access the data at the full dataset level. For quicker access to the scores for a particular model (model_id), we also provide the code to access the data at the model_id level as an asset for each model.")

#variable_group <- c('test_daily')


stac4cast::build_forecast_scores(table_schema = scores_theme_df,
                      #theme_id = 'Scores',
                      table_description = scores_description_create,
                      start_date = scores_min_date,
                      end_date = scores_max_date,
                      id_value = "daily-scores",
                      description_string = build_description,
                      about_string = catalog_config$about_string,
                      about_title = catalog_config$about_title,
                      theme_title = "Scores",
                      destination_path = catalog_config$scores_path,
                      aws_download_path = catalog_config$aws_download_path_scores,
                      link_items = stac4cast::generate_group_values(group_values = names(config$variable_groups)),
                      thumbnail_link = catalog_config$scores_thumbnail,
                      thumbnail_title = catalog_config$scores_thumbnail_title,
                      model_child = TRUE)

## create separate JSON for model landing page
## create separate JSON for model landing page
if (!dir.exists(paste0(catalog_config$scores_path,"models"))){
  dir.create(paste0(catalog_config$scores_path,"models"))
}

stac4cast::build_group_variables(table_schema = scores_theme_df,
                      #theme_id = 'models',
                      table_description = scores_description_create,
                      start_date = scores_min_date,
                      end_date = scores_max_date,
                      id_value = "models",
                      description_string = build_description,
                      about_string = catalog_config$about_string,
                      about_title = catalog_config$about_title,
                      dashboard_string = catalog_config$dashboard_url,
                      dashboard_title = catalog_config$dashboard_title,
                      theme_title = "Models",
                      destination_path = paste0(catalog_config$scores_path,"models"),
                      aws_download_path = catalog_config$aws_download_path_scores,
                      group_var_items = stac4cast::generate_model_items(model_list = theme_models$model_id),
                      thumbnail_link = 'pending',
                      thumbnail_title = 'pending',
                      group_var_vector = NULL,
                      group_sites = NULL)

## CREATE MODELS

## READ IN MODEL METADATA
variable_gsheet <- gsheet2tbl(config$target_metadata_gsheet)

#registered_model_id <- gsheet2tbl(config$model_metadata_gsheet)

# read in model metadata and filter for the relevant project
registered_model_id <- gsheet2tbl(config$model_metadata_gsheet) |>
  filter(`What forecasting challenge are you registering for?` == config$project_id)

scores_sites <- c()

## loop over model ids and extract components if present in metadata table
for (m in theme_models$model_id){

  # make model items directory
  if (!dir.exists(paste0(catalog_config$forecast_path,"models/model_items"))){
    dir.create(paste0(catalog_config$forecast_path,"models/model_items"))
  }

  print(m)
  model_date_range <- scores_data_df |> filter(model_id == m) |> dplyr::summarise(min(date),max(date))
  model_min_date <- model_date_range$`min(date)`
  model_max_date <- model_date_range$`max(date)`

  model_sites <- scores_data_df |> filter(model_id == m) |> distinct(site_id)
  model_vars <- scores_data_df |> filter(model_id == m) |> distinct(variable)

  model_var_duration_df <- scores_data_df |> filter(model_id == m) |> distinct(variable,duration) |>
    mutate(duration_name = ifelse(duration == 'P1D', 'Daily', duration)) |>
    mutate(duration_name = ifelse(duration == 'PT1H', 'Hourly', duration_name)) |>
    mutate(duration_name = ifelse(duration == 'PT30M', '30min', duration_name)) |>
    mutate(duration_name = ifelse(duration == 'P1W', 'Weekly', duration_name))

  model_var_full_name <- model_var_duration_df |>
    left_join((variable_gsheet |>
                 select(variable = `"official" targets name`, full_name = `Variable name`) |>
                 distinct(variable, .keep_all = TRUE)), by = c('variable'))

  model_sites <- scores_data_df |> filter(model_id == m) |> distinct(site_id)

  model_vars <- scores_data_df |> filter(model_id == m) |> distinct(variable) |> left_join(model_var_full_name, by = 'variable')
  model_vars$var_duration_name <- paste0(model_vars$duration_name, " ", model_vars$full_name)

  #model_var_duration_df$full_variable_name <- paste0(model_var_duration_df$variable, "_", model_var_duration_df$duration_name)

  scores_sites <- append(scores_sites,  stac4cast::get_site_coords(site_metadata = catalog_config$site_metadata_url,
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
              destination_path = paste0(catalog_config$scores_path,"models/model_items"),
              aws_download_path = config$scores_bucket, # CHANGE THIS BUCKET NAME
              collection_name = 'scores',
              thumbnail_image_name = NULL,
              table_schema = scores_theme_df,
              table_description = scores_description_create,
              full_var_df = model_vars,
              #code_web_link = registered_model_id$`Web link to model code`[idx],
              code_web_link = 'pending')
}


## BUILD VARIABLE GROUPS

for (i in 1:length(config$variable_groups)){
  print(names(config$variable_groups)[i])

  # check data and skip if no data found
  var_group_data_check <- scores_data_df |>
    filter(variable %in% config$variable_groups[[i]]$variable)

  if (nrow(var_group_data_check) == 0){
    print('No data available for group')
    next
  }



  if (!dir.exists(paste0(catalog_config$scores_path,names(config$variable_groups[i])))){
    dir.create(paste0(catalog_config$scores_path,names(config$variable_groups[i])))
  }

  for(j in 1:length(config$variable_groups[[i]]$variable)){ # FOR EACH VARIABLE WITHIN A MODEL GROUP

    ## restructure variable names
    var_values <- config$variable_groups[[i]]$variable
    var_name <- config$variable_groups[[i]]$variable[j]
    print(var_name)

    # check data and skip if no data found
    var_data_check <- scores_data_df |>
      filter(variable == var_name)

    if (nrow(var_data_check) == 0){
      print('No data available for variable')
      next
    }

    duration_name <- config$variable_groups[[i]]$duration[j]

    # match variable with full name in gsheet
    var_name_full <- variable_gsheet[which(variable_gsheet$`"official" targets name` %in% var_values),1][[1]]

    ## create new vector to store duration names
    duration_values <- config$variable_groups[[i]]$duration
    duration_values[which(duration_values == 'P1D')] <- 'Daily'
    duration_values[which(duration_values == 'PT1H')] <- 'Hourly'
    duration_values[which(duration_values == 'PT30M')] <- '30min'
    duration_values[which(duration_values == 'P1W')] <- 'Weekly'

    var_name_combined_list <- paste0(duration_values,'_',var_name_full)

    ## CREATE VARIABLE GROUP JSONS
    group_description <- paste0('This page includes variables for the ',names(config$variable_groups[i]),' group.')

    ## find group sites
    find_group_sites <- scores_data_df |>
      filter(variable %in% var_values) |>
      distinct(site_id)

    stac4cast::build_group_variables(table_schema = scores_theme_df,
                          #theme_id = names(config$variable_groups[i]),
                          table_description = scores_description_create,
                          start_date = scores_min_date,
                          end_date = scores_max_date,
                          id_value = names(config$variable_groups[i]),
                          description_string = group_description,
                          about_string = catalog_config$about_string,
                          about_title = catalog_config$about_title,
                          dashboard_string = catalog_config$dashboard_url,
                          dashboard_title = catalog_config$dashboard_title,
                          theme_title = names(config$variable_groups[i]),
                          destination_path = paste0(catalog_config$scores_path,names(config$variable_groups[i])),
                          aws_download_path = catalog_config$aws_download_path_scores,
                          group_var_items = stac4cast::generate_group_variable_items(variables = var_name_combined_list),
                          thumbnail_link = config$variable_groups[[i]]$thumbnail_link,
                          thumbnail_title = config$variable_groups[[i]]$thumbnail_title,
                          group_var_vector = unique(var_values),
                          group_sites = find_group_sites$site_id)

    if (!dir.exists(paste0(catalog_config$scores_path,names(config$variable_groups)[i],'/',var_name_combined_list[j]))){
      dir.create(paste0(catalog_config$scores_path,names(config$variable_groups)[i],'/',var_name_combined_list[j]))
    }

    var_data <- scores_data_df |>
      filter(variable == var_name,
             duration == duration_name)

    var_date_range <- var_data |> dplyr::summarise(min(date),max(date))
    var_min_date <- var_date_range$`min(date)`
    var_max_date <- var_date_range$`max(date)`

    var_models <- var_data |> distinct(model_id)

    find_var_sites <- scores_data_df |>
      filter(variable == var_name) |>
      distinct(site_id)

    var_description <- paste0('This page includes all models for the ',var_name_combined_list[j],' variable.')

    var_path <- gsub('forecasts','scores',var_data$path[1])

    stac4cast::build_group_variables(table_schema = scores_theme_df,
                          #theme_id = var_name_combined_list[j],
                          table_description = scores_description_create,
                          start_date = var_min_date,
                          end_date = var_max_date,
                          id_value = var_name_combined_list[j],
                          description_string = var_description,
                          about_string = catalog_config$about_string,
                          about_title = catalog_config$about_title,
                          dashboard_string = catalog_config$dashboard_url,
                          dashboard_title = catalog_config$dashboard_title,
                          theme_title = var_name_combined_list[j],
                          destination_path = file.path(catalog_config$scores_path,names(config$variable_groups)[i],var_name_combined_list[j]),
                          aws_download_path = var_path,
                          group_var_items = stac4cast::generate_variable_model_items(model_list = var_models$model_id),
                          thumbnail_link = 'pending',
                          thumbnail_title = 'pending',
                          group_var_vector = NULL,
                          group_sites = find_var_sites$site_id)

  }


}
