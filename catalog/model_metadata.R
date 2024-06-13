Sys.setenv(AWS_ACCESS_KEY_ID=Sys.getenv("OSN_KEY"),
           AWS_SECRET_ACCESS_KEY=Sys.getenv("OSN_SECRET"))

config <- yaml::read_yaml("challenge_configuration.yaml")

endpoint <- config$endpoint

minioclient::install_mc()

minioclient::mc_alias_set("osn",
                          config$endpoint,
                          Sys.getenv("OSN_KEY"),
                          Sys.getenv("OSN_SECRET"))

googlesheets4::gs4_deauth()
registered_models <- googlesheets4::read_sheet(config$model_metadata_gsheet) |>
  dplyr::filter(`What forecasting challenge are you registering for?` == config$project_id,
                !grepl("example",model_id))

# registered_models <- gsheet::gsheet2tbl(config$model_metadata_gsheet) |>
#   dplyr::filter(`What forecasting challenge are you registering for?` == config$project_id,
#                 !is.na(`Which category best matches your modeling approach?`))

for(i in 1:nrow(registered_models)){

  print(registered_models$model_id[i])

  #Need to get from forecast output
  progagates_method <- "Infer from family column in archived forecasts"

  metadata <- list()

  metadata$creator$individual_name <- "Pending"
  metadata$creator$electronicMailAddress <- "Pending"
  metadata$creator$organizationName <- "Pending"
  metadata$model_id <- registered_models$model_id[i]
  metadata$model_description$intellectualRights <- "https://creativecommons.org/licenses/by/4.0/"
  metadata$model_description$name <- registered_models$`Long name of the model`[i]
  metadata$model_description$type <- registered_models$`Which category best matches your modeling approach?`[i]
  metadata$model_description$repository <- registered_models$`Web link to model code`[i]


  ## handle models with no metadata present
  if (is.na(registered_models$`Which category best matches your modeling approach?`[i])){
    print('Skipping model due to missing metadata')
    metadata$uncertainty$initial_conditions$present <- "Unknown"
    metadata$uncertainty$drivers$present <- "Unknown"
    metadata$uncertainty$process$present <- "Unknown"
    metadata$uncertainty$obs_error$present <- "Unknown"
    metadata$uncertainty$structural_error$present <- "Unknown"
    metadata$uncertainty$random_effects$present <- "Unknown"

    next()
  }

  # Initial Conditions

  if(registered_models$`Do your forecasts include uncertainty from initial conditions?`[i] %in% c("Yes and they were estimated from data", "Yes")){
    metadata$uncertainty$initial_conditions$present <- TRUE
    metadata$uncertainty$initial_conditions$data_driven <- TRUE
    metadata$uncertainty$initial_conditions$progagates$type <- progagates_method
  }else if(registered_models$`Do your forecasts include uncertainty from initial conditions?`[i] %in% c("Yes and they were not estimated from data (e.g., assumed initial conditions were the model equilibrium)", "Yes")){
    metadata$uncertainty$initial_conditions$present <- TRUE
    metadata$uncertainty$initial_conditions$data_driven <- FALSE
    metadata$uncertainty$initial_conditions$progagates$type <- progagates_method
  }else if(registered_models$`Do your forecasts include uncertainty from initial conditions?`[i] == "No"){
    if(registered_models$`Is your forecast model dynamic? (i.e. is tomorrow’s forecast dependent on today’s forecast)?`[i] == "Yes"){
      metadata$uncertainty$initial_conditions$present <- TRUE
      metadata$uncertainty$initial_conditions$data_driven <- FALSE
    }else{
      metadata$uncertainty$initial_conditions$present <- FALSE
    }
  }else{
    metadata$uncertainty$initial_conditions$present <- "Unknown"
  }

  if(registered_models$`Do you update your initial conditions or parameters between forecast submissions using newly available data (i.e., data assimilation)?`[i] %in%
     c("Initial conditions", "Both initial conditions and parameters")){
    metadata$uncertainty$initial_conditions$assimilation$type = registered_models$`What method did you use if you updated your initial conditions or parameters using data assimilation?`[i]
  }

  #Parameters

  if(registered_models$`Does your model include parameters?`[i] %in% c("Yes and they are not estimated from data", "Yes")){
    metadata$uncertainty$parameters$present <- TRUE
    metadata$uncertainty$parameters$data_driven <- FALSE
    if(registered_models$`Does your forecast include uncertainty from the model parameters?`[i] == "Yes"){
      metadata$uncertainty$parameters$progagates$type <- progagates_method
    }
  }else if(registered_models$`Does your forecast include uncertainty from the model parameters?`[i] %in% c("Yes and at least one is estimated from data", "Yes")){
    metadata$uncertainty$parameters$present <- TRUE
    metadata$uncertainty$parameters$data_driven <- TRUE
    if(registered_models$`Does your forecast include uncertainty from the model parameters?`[i] == "Yes"){
      metadata$uncertainty$parameters$progagates$type <- progagates_method
    }
  }

  if(registered_models$`Do you update your initial conditions or parameters between forecast submissions using newly available data (i.e., data assimilation)?`[i] %in%
     c("Parameter", "Both initial conditions and parameters")){
    metadata$uncertainty$parameters$assimilation$type = registered_models$`What method did you use if you updated your initial conditions or parameters using data assimilation?`[i]
  }

  # Drivers

  if(registered_models$`Does your forecast include uncertainty from drivers (i.e., ensemble weather forecasts)?`[i] == "Yes"){
    metadata$uncertainty$drivers$present <- TRUE
    metadata$uncertainty$drivers$data_driven <- TRUE
    metadata$uncertainty$drivers$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from drivers (i.e., ensemble weather forecasts)?`[i] == "No"){
    if(registered_models$`Does the forecast use drivers?`[i] == "Yes"){
      metadata$uncertainty$drivers$present <- TRUE
      metadata$uncertainty$drivers$data_driven <- TRUE
    }else{
      metadata$uncertainty$drivers$present <- FALSE
    }
  }else{
    metadata$uncertainty$drivers$present <- "Unknown"
  }

  #Process model

  if(registered_models$`Does your forecast include uncertainty from the model (process uncertainty)?`[i] %in% c("Yes and the uncertainty was estimated from data", "Yes")){
    metadata$uncertainty$process_error$present <- TRUE
    metadata$uncertainty$process_error$data_driven <- TRUE
    metadata$uncertainty$process_error$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from the model (process uncertainty)?`[i] %in% c("Yes and the uncertainty was not estimated from data","Yes")){
    metadata$uncertainty$process_error$present <- TRUE
    metadata$uncertainty$process_error$data_driven <- FALSE
    metadata$uncertainty$process_error$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from the model (process uncertainty)?`[i] == "No"){
    metadata$uncertainty$process_error$present <- FALSE
  }else{
    metadata$uncertainty$process$present <- "Unknown"
  }

  # Measurement error

  if(registered_models$`Does your forecast include uncertainty from measurement noise?`[i] %in% c("Yes and the noise was estimated from data", "Yes")){
    metadata$uncertainty$obs_error$present <- TRUE
    metadata$uncertainty$obs_error$data_driven <- TRUE
    metadata$uncertainty$obs_error$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from measurement noise?`[i] %in% c("Yes and the noise was not estimated from data", "Yes")){
    metadata$uncertainty$obs_error$present <- TRUE
    metadata$uncertainty$obs_error$data_driven <- FALSE
    metadata$uncertainty$obs_error$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from measurement noise?`[i] == "No"){
    metadata$uncertainty$obs_error$present <- FALSE
  }else{
    metadata$uncertainty$obs_error$present <- "Unknown"
  }

  #Structural uncertainty

  #How is structural error "data driven"

  if(registered_models$`Does your forecast include uncertainty from using different models?`[i] == "Yes"){
    metadata$uncertainty$structural_error$present <- TRUE
    metadata$uncertainty$structural_error$data_driven <- FALSE
    metadata$uncertainty$structural_error$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from using different models?`[i] == "No"){
    metadata$uncertainty$structural_error$present <- FALSE
  }else{
    metadata$uncertainty$structural_error$present <- "Unknown"
  }

  # Random effects

  if(registered_models$`Does your forecast include uncertainty from parameter random effects?`[i] %in% c("Yes and the uncertainty was estimated from data", "Yes")){
    metadata$uncertainty$random_effects$present <- TRUE
    metadata$uncertainty$random_effects$data_driven <- TRUE
    metadata$uncertainty$random_effects$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from parameter random effects?`[i] %in% c("Yes and the uncertainty was not estimated from data (uncommon)", "Yes")){
    metadata$uncertainty$random_effects$present <- TRUE
    metadata$uncertainty$random_effects$data_driven <- FALSE
    metadata$uncertainty$random_effects$progagates$type <- progagates_method
  }else if(registered_models$`Does your forecast include uncertainty from parameter random effects?`[i] == "No"){
    metadata$uncertainty$random_effects$present <- FALSE
  }else{
    metadata$uncertainty$random_effects$present <- "Unknown"
  }

  file_name <- paste0(metadata$model_id, ".json")
  jsonlite::write_json(metadata, path = file.path("catalog",file_name), pretty = TRUE)

  minioclient::mc_cp(file.path("catalog",file_name), file.path("osn",config$model_metadata_bucket, file_name))

  unlink(file.path("catalog",file_name))
}
