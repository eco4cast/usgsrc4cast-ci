
library(read4cast)
library(score4cast)
library(readr)
library(dplyr)
library(arrow)
library(glue)
library(here)
library(minioclient)
library(tools)
library(fs)
library(stringr)
library(lubridate)
source("R/eco4cast-helpers/forecast_output_validator.R")

install_mc()

config <- yaml::read_yaml("challenge_configuration.yaml")

sites <- readr::read_csv(config$site_table,
                         show_col_types = FALSE) |>
  select(site_id, latitude, longitude)

minioclient::mc_alias_set("s3_store",
                          config$endpoint,
                          Sys.getenv("OSN_KEY"),
                          Sys.getenv("OSN_SECRET"))

minioclient::mc_alias_set("submit",
                          config$submissions_endpoint,
                          Sys.getenv("AWS_ACCESS_KEY_SUBMISSIONS"),
                          Sys.getenv("AWS_SECRET_ACCESS_KEY_SUBMISSIONS"))

# Since 2026-09-08 the NRP key has had ListBucket only on the submissions
# bucket: both GetObject and DeleteObject return "Insufficient permissions". The
# bucket's own policy, however, grants GetObject-by-ACL and DeleteObject to
# Principal:* , so an unauthenticated client can do both - it just cannot list.
# So we list with the authenticated alias above and do the reads and deletes
# through this anonymous one. Drop it once NRP restores the key's permissions.
minioclient::mc_alias_set("submit_read", config$submissions_endpoint, "", "")

message(paste0("Starting Processing Submissions ", Sys.time()))

local_dir <- file.path(here::here(), "submissions")
unlink(local_dir, recursive = TRUE)
fs::dir_create(local_dir)

# Removal is now best-effort (see mark_processed below), so we also keep our own
# record of what has been handled, on OSN where we have write access, and filter
# those out before downloading. That keeps the pipeline correct even if deleting
# from the submissions bucket stops working again. usgsrc4cast and neon4cast
# share the OSN bucket, so this manifest uses a challenge-specific filename.
manifest_object <- paste0("s3_store/", config$processed_submissions)
manifest_local <- file.path(tempdir(), "processed_submissions.csv")

processed <- tryCatch({
  minioclient::mc_cp(manifest_object, manifest_local)
  manifest <- readr::read_csv(manifest_local, show_col_types = FALSE)
  if ("key" %in% names(manifest)) as.character(manifest$key) else character(0)
}, error = function(e) {
  message("No processed-submissions record found; starting a new one.")
  character(0)
})

marked <- 0L   # submissions handled in this run
removed <- 0L  # objects deleted from the bucket: newly handled plus backlog

# The bucket policy grants DeleteObject to Principal:* , so the anonymous alias
# can clear the bucket even though our key cannot. Best effort only: callers
# have already recorded the submission, so a failure here costs space on the
# bucket, not correctness, and must not abort the run.
remove_from_bucket <- function(key) {
  tryCatch({
    minioclient::mc_rm(paste0("submit_read/", config$submissions_bucket, "/", key))
    removed <<- removed + 1L
    TRUE
  }, error = function(e) {
    warning("could not remove ", key, " from the submissions bucket: ",
            conditionMessage(e), call. = FALSE)
    FALSE
  })
}

mark_processed <- function(key) {
  # Record first, remove second. If the removal succeeds but the record was
  # never written we would reprocess a submission that no longer exists; this
  # order fails safe in the other direction instead.
  processed <<- unique(c(processed, key))
  marked <<- marked + 1L
  readr::write_csv(data.frame(key = processed), manifest_local)
  minioclient::mc_cp(manifest_local, manifest_object)

  remove_from_bucket(key)
}

message("Listing submissions ...")

# List the whole bucket with the authenticated alias (the only thing the key can
# still do) and keep this challenge's submissions. neon4cast processes the rest
# of the shared bucket, so filtering to project_id here is what divides the work.
all_keys <- minioclient::mc_ls(paste0("submit/", config$submissions_bucket),
                               recursive = TRUE,
                               details = TRUE)$key

wanted <- all_keys[stringr::str_detect(all_keys, config$project_id)]
submission_keys <- setdiff(wanted, processed)

message(sprintf("%d objects in bucket, %d for %s, %d already processed, %d to download",
                length(all_keys),
                length(wanted),
                config$project_id,
                length(wanted) - length(submission_keys),
                length(submission_keys)))

# Submissions already recorded as handled but still sitting in the bucket,
# because removal failed or was never attempted on an earlier run. Clearing them
# here is what actually drains the backlog: they are filtered out of
# submission_keys above, so they never reach mark_processed() again.
stale <- intersect(wanted, processed)
if (length(stale) > 0) {
  message(sprintf("Clearing %d already-processed submission(s) left in the bucket",
                  length(stale)))
  for (key in stale) remove_from_bucket(key)
}

if(length(submission_keys) > 0){
  message("Downloading forecasts ...")

  # Replaces mc_mirror(), which cannot work while list and read live with
  # different identities. Keys are copied one at a time through the anonymous
  # alias, preserving the bucket's nested layout for the dir_ls() walk below. A
  # single unreadable object is reported and skipped rather than aborting.
  failed <- character(0)
  for (key in submission_keys) {
    dest <- file.path(local_dir, key)
    fs::dir_create(dirname(dest))
    copied <- tryCatch({
      minioclient::mc_cp(paste0("submit_read/", config$submissions_bucket, "/", key), dest)
      TRUE
    }, error = function(e) {
      warning("could not download ", key, ": ", conditionMessage(e), call. = FALSE)
      FALSE
    })
    if (!isTRUE(copied)) failed <- c(failed, key)
  }

  submissions <- fs::dir_ls(local_dir,
                            recurse = TRUE,
                            type = "file")

  message(sprintf("Downloaded %d of %d submissions",
                  length(submission_keys) - length(failed),
                  length(submission_keys)))
  if (length(failed) > 0) {
    message("Skipped unreadable submissions: ", paste(failed, collapse = ", "))
  }
  print(submissions)

  if(length(submissions) > 0){

    Sys.unsetenv("AWS_DEFAULT_REGION")
    Sys.unsetenv("AWS_S3_ENDPOINT")
    Sys.setenv(AWS_EC2_METADATA_DISABLED="TRUE")

    s3 <- arrow::s3_bucket(config$forecasts_bucket,
                           endpoint_override = config$endpoint,
                           access_key = Sys.getenv("OSN_KEY"),
                           secret_key = Sys.getenv("OSN_SECRET"))

    s3_scores <- arrow::s3_bucket(file.path(config$scores_bucket,"parquet"),
                                  endpoint_override = config$endpoint,
                                  access_key = Sys.getenv("OSN_KEY"),
                                  secret_key = Sys.getenv("OSN_SECRET"))


    s3_inventory <- arrow::s3_bucket(dirname(config$inventory_bucket),
                                     endpoint_override = config$endpoint,
                                     access_key = Sys.getenv("OSN_KEY"),
                                     secret_key = Sys.getenv("OSN_SECRET"))

    s3_inventory$CreateDir(paste0("inventory/catalog/forecasts/project_id=", config$project_id))

    s3_inventory <- arrow::s3_bucket(paste0(config$inventory_bucket,
                                            "/catalog/forecasts/project_id=",
                                            config$project_id),
                                     endpoint_override = config$endpoint,
                                     access_key = Sys.getenv("OSN_KEY"),
                                     secret_key = Sys.getenv("OSN_SECRET"))

    inventory_df <- arrow::open_dataset(s3_inventory) |> dplyr::collect()

    time_stamp <- format(Sys.time(), format = "%Y%m%d%H%M%S")

    print(inventory_df)

    for(i in 1:length(submissions)){

      curr_submission <- basename(submissions[i])
      # Bucket-relative path (not the basename): submissions may sit under a
      # prefix, and the manifest must match what mc_ls() returns to skip them.
      curr_key <- as.character(fs::path_rel(submissions[i], local_dir))
      curr_project_id <-  stringr::str_split(curr_submission, "-")[[1]][1]
      if(curr_project_id != config$project_id){ # if the file doesn't have appropriate project_id, then move on to next file
        next
      }
      file_name_model_id <-  stringr::str_split(tools::file_path_sans_ext(tools::file_path_sans_ext(curr_submission)), "-")[[1]][5]
      file_name_reference_datetime <- lubridate::as_datetime(paste0(stringr::str_split(curr_submission, "-")[[1]][2:4], collapse = "-"))
      submission_dir <- dirname(submissions[i])
      print(curr_submission)

      if((tools::file_ext(curr_submission) %in% c("gz", "csv", "nc"))){

        # Use the real path: downloads preserve the bucket's nested layout, so
        # the file lives under a project_id/ subdir, not directly in local_dir.
        valid <- forecast_output_validator(submissions[i])

        if(valid){

          # still OK to use read4cast as there aren't challenge-specific things
          # in the package, other than list of all potential target variables,
          # which could be updated if we forecast new variables (but for usgsrc4cast we're forecasting chla)
          fc <- read4cast::read_forecast(submissions[i])

          pub_datetime <- strftime(Sys.time(), format = "%Y-%m-%d %H:%M:%S", tz = "UTC")

          if(!"duration" %in% names(fc)){
            # if(theme == "terrestrial_30min"){
            #   fc <- fc |> dplyr::mutate(duration = "PT30M")
            # }else if(theme %in% c("ticks","beetles")){
            #   fc <- fc |> dplyr::mutate(duration = "P1W")
            # }else if(theme %in% c("aquatics","phenology","terrestrial_daily")){
            #   fc <- fc |> dplyr::mutate(duration = "P1D")
            # }else{
            # if(stringr::str_detect(fc$datetime[1], ":")){
            #   fc <- fc |> dplyr::mutate(duration = "P1H")
            # }else{
            fc <- fc |> dplyr::mutate(duration = "P1D") # currently only have "P1D" duration for usgsrc4cast
            # }
          }


          if(!("model_id" %in% colnames(fc))){
            fc <- fc |> mutate(model_id = file_name_model_id)
          }else if(fc$model_id[1] == "null"){
            fc <- fc |> mutate(model_id = file_name_model_id)
          }


          if(!("reference_datetime" %in% colnames(fc))){
            fc <- fc |> mutate(reference_datetime = file_name_reference_datetime)
          }

          fc <- fc |>
            dplyr::mutate(pub_datetime = lubridate::as_datetime(pub_datetime),
                          datetime = lubridate::as_datetime(datetime),
                          reference_datetime = lubridate::as_datetime(reference_datetime),
                          reference_date = lubridate::as_date(reference_datetime),
                          parameter = as.character(parameter),
                          project_id = config$project_id) |>
            dplyr::filter(datetime >= reference_datetime)

          print(head(fc))
          s3$CreateDir(paste0("parquet/"))
          fc |> arrow::write_dataset(s3$path(paste0("parquet")), format = 'parquet',
                                     partitioning = c("project_id",
                                                      "duration",
                                                      "variable",
                                                      "model_id",
                                                      "reference_date"))

          s3$CreateDir(paste0("summaries"))
          fc |>
            dplyr::summarise(prediction = mean(prediction),
                             .by = dplyr::any_of(c("site_id", "datetime",
                                                   "reference_datetime", "family",
                                                   "depth_m", "duration", "model_id",
                                                   "parameter", "pub_datetime",
                                                   "reference_date", "variable", "project_id"))) |>
            score4cast::summarize_forecast(extra_groups = c("duration", "project_id", "depth_m")) |>
            dplyr::mutate(reference_date = lubridate::as_date(reference_datetime)) |>
            arrow::write_dataset(s3$path("summaries"), format = 'parquet',
                                 partitioning = c("project_id",
                                                  "duration",
                                                  "variable",
                                                  "model_id",
                                                  "reference_date"))

          bucket <- config$forecasts_bucket
          curr_inventory <- fc |>
            mutate(reference_date = lubridate::as_date(reference_datetime),
                   date = lubridate::as_date(datetime),
                   pub_date = lubridate::as_date(pub_datetime)) |>
            distinct(duration, model_id, site_id, reference_date, variable, date, project_id, pub_date) |>
            mutate(path = glue::glue("{bucket}/parquet/project_id={project_id}/duration={duration}/variable={variable}"),
                   path_full = glue::glue("{bucket}/parquet/project_id={project_id}/duration={duration}/variable={variable}/model_id={model_id}/reference_date={reference_date}/part-0.parquet"),
                   path_summaries = glue::glue("{bucket}/summaries/project_id={project_id}/duration={duration}/variable={variable}/model_id={model_id}/reference_date={reference_date}/part-0.parquet"),
                   endpoint =config$endpoint)


          curr_inventory <- dplyr::left_join(curr_inventory, sites, by = "site_id")

          inventory_df <- dplyr::bind_rows(inventory_df, curr_inventory)

          arrow::write_dataset(inventory_df, path = s3_inventory)

          submission_timestamp <- paste0(submission_dir,"/T", time_stamp, "_", basename(submissions[i]))
          fs::file_copy(submissions[i], submission_timestamp)
          raw_bucket_object <- paste0("s3_store/",
                                      config$forecasts_bucket,
                                      "/raw/project_id=", config$project_id, "/",
                                      basename(submission_timestamp))
          print(raw_bucket_object)

          minioclient::mc_cp(submission_timestamp, paste0(dirname(raw_bucket_object),"/", basename(submission_timestamp)))

          if(length(minioclient::mc_ls(raw_bucket_object)) > 0){
            mark_processed(curr_key)
          }

          rm(fc)
          gc()

        } else {

          submission_timestamp <- paste0(submission_dir,"/T", time_stamp, "_", basename(submissions[i]))
          fs::file_copy(submissions[i], submission_timestamp)
          raw_bucket_object <- paste0("s3_store/",
                                      config$forecasts_bucket,
                                      "/raw/project_id=", config$project_id, "/",
                                      basename(submission_timestamp))

          minioclient::mc_cp(submission_timestamp, paste0(dirname(raw_bucket_object),"/", basename(submission_timestamp)))

          if(length(minioclient::mc_ls(raw_bucket_object)) > 0){
            mark_processed(curr_key)
          }

        }
      }
    }

    message("writing inventory")

    arrow::write_dataset(inventory_df, path = s3_inventory)

    s3_inventory <- arrow::s3_bucket(paste0(config$inventory_bucket),
                                     endpoint_override = config$endpoint,
                                     access_key = Sys.getenv("OSN_KEY"),
                                     secret_key = Sys.getenv("OSN_SECRET"))

    inventory_df |> dplyr::distinct(model_id, project_id) |>
      arrow::write_csv_arrow(s3_inventory$path("model_id/model_id-project_id-inventory.csv"))

  }

  unlink(local_dir, recursive = TRUE)

  message(sprintf("Processed %d submission(s) this run, removed %d object(s) from the bucket; %d recorded in total",
                  marked, removed, length(processed)))
  if (marked > 0L && removed == 0L) {
    message("Nothing could be removed: the bucket will keep growing until either ",
            "the anonymous delete or the NRP key's DeleteObject permission works.")
  }

  message(paste0("Completed Processing Submissions ", Sys.time()))
}else{
  message("No submitted files to process")
}


