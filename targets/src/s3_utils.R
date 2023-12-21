
#' helper function for pushing file to s3
#'
#' @param config configuration file of the challenge
#' @param local_file_name targets file name
#' @param s3_file_name file to write to s3 #'
push_to_s3 <- function(
    config,
    local_file_name,
    s3_file_name
){

  targets <- read_csv(local_file_name)
  # duration hard coded for now
  bucket_path <- glue::glue("{config$targets_bucket}/project_id={config$project_id}/duration=P1D")

  s3 <- arrow::s3_bucket(bucket_path,
                         endpoint_override = config$endpoint,
                         access_key = Sys.getenv("OSN_KEY"),
                         secret_key = Sys.getenv("OSN_SECRET"))

  sink <- s3$path(s3_file_name)

  # write to s3
  arrow::write_csv_arrow(x = targets,
                         sink = sink)

  return(sink)
}

