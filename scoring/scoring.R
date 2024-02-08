library(score4cast)
library(arrow)

past_days <- 365
n_cores <- 8

setwd(here::here())

Sys.setenv(AWS_ACCESS_KEY_ID=Sys.getenv("OSN_KEY"),
           AWS_SECRET_ACCESS_KEY=Sys.getenv("OSN_SECRET"))

ignore_sigpipe()

config <- yaml::read_yaml("challenge_configuration.yaml")

endpoint <- config$endpoint

s3 <- arrow::s3_bucket(dirname(config$scores_bucket),
                       endpoint_override = endpoint,
                       access_key = Sys.getenv("OSN_KEY"),
                       secret_key = Sys.getenv("OSN_SECRET"))

s3$CreateDir("inventory")
s3$CreateDir("prov")
s3$CreateDir("scores")

Sys.setenv("AWS_EC2_METADATA_DISABLED"="TRUE")
Sys.unsetenv("AWS_DEFAULT_REGION")

s3_inv <- arrow::s3_bucket(paste0(config$inventory_bucket,"/catalog/forecasts/project_id=",
                                  config$project_id),
                           endpoint_override = endpoint)

variable_duration <- arrow::open_dataset(s3_inv) |>
  dplyr::distinct(variable, duration, project_id) |>
  dplyr::collect()

future::plan("future::multisession", workers = n_cores)

#future::plan("future::sequential", workers = n_cores)

furrr::future_walk(1:nrow(variable_duration), function(k, variable_duration, config, endpoint){

  Sys.setenv(AWS_ACCESS_KEY_ID=Sys.getenv("OSN_KEY"),
             AWS_SECRET_ACCESS_KEY=Sys.getenv("OSN_SECRET"))

  variable <- variable_duration$variable[k]
  duration <- variable_duration$duration[k]
  project_id <- variable_duration$project_id[k]

  print(variable_duration[k,])

  s3_targets <- arrow::s3_bucket(glue::glue(config$targets_bucket,"/project_id={project_id}"),
                                 endpoint_override = endpoint)
  s3_scores <- arrow::s3_bucket(config$scores_bucket,
                                endpoint_override = endpoint)
  s3_prov <- arrow::s3_bucket(config$prov_bucket,
                              endpoint_override = endpoint)
  s3_inv <- arrow::s3_bucket(paste0(config$inventory_bucket,"/catalog/forecasts"),
                             endpoint_override = endpoint)

  local_prov <- paste0(project_id,"-",duration,"-",variable, "-scoring_provenance.csv")

  if (!(local_prov %in% s3_prov$ls())) {
    prov_df <- dplyr::tibble(date = Sys.Date(),
                             new_id = "start",
                             model_id = "start",
                             reference_date = "start",
                             pub_date = "start")
  }else{
    path <- s3_prov$path(local_prov)
    prov_df <- arrow::read_csv_arrow(path)
  }

  s3_scores_path <- s3_scores$path(glue::glue("parquet/project_id={project_id}/duration={duration}/variable={variable}"))

  s3_targets <- arrow::s3_bucket(glue::glue(config$targets_bucket),
                                 endpoint_override = endpoint)

  target <- arrow::open_csv_dataset(s3_targets,
                                    schema = arrow::schema(
                                      project_id = arrow::string(),
                                      site_id = arrow::string(),
                                      datetime = arrow::timestamp(unit = "ns"), # timezone = "UTC"),
                                      duration = arrow::string(),
                                      #depth_m = arrow::float(), #project_specific
                                      variable = arrow::string(),
                                      observation = arrow::float()),
                                    skip = 1) |>
    dplyr::filter(variable == variable_duration$variable[k],
                  duration == variable_duration$duration[k],
                  project_id == variable_duration$project_id[k]) |>
    dplyr::collect()

  curr_variable <- variable
  curr_duration <- duration
  curr_project_id <- project_id

  groupings <- arrow::open_dataset(s3_inv,
                                   schema = arrow::schema(
                                     duration = arrow::string(),
                                     model_id = arrow::string(),
                                     site_id = arrow::string(),
                                     reference_date = arrow::date32(),
                                     variable = arrow::string(),
                                     date = arrow::date32(),
                                     project_id = arrow::string(),
                                     pub_date = arrow::date32(),
                                     path = arrow::string(),
                                     path_full = arrow::string(),
                                     path_summaries = arrow::string(),
                                     endpoint = arrow::string(),
                                     latitude = arrow::float(),
                                     longitude = arrow::float(),
                                   )) |>
    dplyr::filter(variable == curr_variable,
                  duration == curr_duration,
                  project_id == curr_project_id) |>
    dplyr::select(-site_id) |>
    dplyr::collect() |>
    dplyr::distinct() |>
    dplyr::filter(date > Sys.Date() - lubridate::days(past_days),
                  date <= lubridate::as_date(max(target$datetime))) |>
    dplyr::group_by(model_id, date, duration, path, endpoint) |>
    dplyr::arrange(reference_date, pub_date) |>
    dplyr::summarise(reference_date = paste(unique(reference_date), collapse=","),
                     pub_date = paste(unique(pub_date), collapse=","),
                     .groups = "drop")

  if(nrow(groupings) > 0){

    new_prov <- purrr::map_dfr(1:nrow(groupings), function(j, groupings, prov_df, s3_scores_path, curr_variable){

      group <- groupings[j,]
      ref <- group$date

      tg <- target |>
        #dplyr::mutate(depth_m = ifelse(!is.na(depth_m), round(depth_m, 2), depth_m)) |>  #project_specific
        dplyr::filter(lubridate::as_date(datetime) >= ref,
                      lubridate::as_date(datetime) < ref+lubridate::days(1))

      id <- rlang::hash(list(group[, c("model_id","reference_date","date","pub_date")],  tg))

      if (!(score4cast:::prov_has(id, prov_df, "new_id"))){

        print(group)


        reference_dates <- unlist(stringr::str_split(group$reference_date, ","))

        ref_upper <- (lubridate::as_date(ref)+lubridate::days(1))
        fc <- arrow::open_dataset(paste0("s3://anonymous@",group$path,"/model_id=",group$model_id,"?endpoint_override=",group$endpoint)) |>
          dplyr::filter(reference_date %in% reference_dates,
                        lubridate::as_date(datetime) >= ref,
                        lubridate::as_date(datetime) < ref_upper) |>
          dplyr::collect()

        fc |>
          #dplyr::mutate(depth_m = ifelse(!is.na(depth_m), round(depth_m, 2), depth_m)) |> #project_specific
          dplyr::mutate(variable = curr_variable,
                        project_id = curr_project_id) |>
          #If for some reason, a forecast has multiple values for a parameter from a specific forecast, then average
          dplyr::summarise(prediction = mean(prediction), .by = dplyr::any_of(c("site_id", "datetime", "reference_datetime", "family",
                                                                                "parameter", "pub_datetime", "reference_date", "variable", "project_id"))) |>
          #score4cast::crps_logs_score(tg, extra_groups = c("depth_m","project_id")) |> #project_specific
          score4cast::crps_logs_score(tg, extra_groups = c("project_id")) |> #project_specific
          dplyr::mutate(date = group$date,
                        model_id = group$model_id) |>
          dplyr::select(-variable,-project_id) |>
          arrow::write_dataset(s3_scores_path,
                               partitioning = c("model_id", "date"))

        curr_prov <- dplyr::tibble(date = Sys.Date(),
                                   new_id = id,
                                   model_id = group$model_id,
                                   reference_date = group$reference_date,
                                   pub_date = group$pub_date)
      }else{
        curr_prov <- NULL
      }
    },
    groupings, prov_df, s3_scores_path,curr_variable)

    prov_df <- dplyr::bind_rows(prov_df, new_prov)
    arrow::write_csv_arrow(prov_df, s3_prov$path(local_prov))
  }
},
variable_duration,  config, endpoint
)
