## Technically this could become arrow-based

#' submit forecast to EFI forecast challenge
#'
#' @inheritParams forecast_output_validator
#' @param forecast_file the path to the forecast file to submit
#' @param project_id the forecast challenge project_id to submit to
#' @param metadata path to metadata file
#' @param ask should we prompt for a go before submission?
#' @param s3_region subdomain (leave as is for EFI challenge)
#' @param s3_endpoint root domain (leave as is for EFI challenge)
#' @export
submit <- function(forecast_file,
                   project_id,
                   metadata = NULL,
                   ask = interactive(),
                   s3_region = "s3-west",
                   s3_endpoint = "nrp-nautilus.io"
){
  ## Temporarily isolate from any existing AWS credentials
  aws_vars <- c("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN", "AWS_DEFAULT_PROFILE", "AWS_PROFILE")
  saved_env <- Sys.getenv(aws_vars, unset = NA)
  Sys.unsetenv(aws_vars)

  aws_dir <- path.expand("~/.aws")
  aws_bak <- path.expand("~/.aws.bak")
  renamed_aws <- FALSE
  if (file.exists(aws_dir)) {
    file.rename(aws_dir, aws_bak)
    renamed_aws <- TRUE
  }

  on.exit({
    # Restore environment variables
    for (v in names(saved_env)) {
      if (!is.na(saved_env[[v]])) {
        Sys.setenv(saved_env[v])
      }
    }
    # Restore ~/.aws directory
    if (renamed_aws && file.exists(aws_bak)) {
      file.rename(aws_bak, aws_dir)
    }
  }, add = TRUE)

  message("validating that file matches required standard")
  go <- forecast_output_validator(forecast_file)

  if(!go){

    warning(paste0("forecasts was not in a valid format and was not submitted\n",
                   "First, try reinstalling neon4cast (remotes::install_github('eco4cast\\neon4cast'), sourcing usgsrc4cast-specific functions (https://projects.ecoforecast.org/usgsrc4cast-ci/instructions.html#uploading-forecast), restarting R, and trying again\n",
                   "Second, see https://projects.ecoforecast.org/usgsrc4cast-ci/instructions.html for more information on the file format"))
    return(invisible(FALSE))
  }

  if(go & ask){
    go <- utils::askYesNo("Forecast file is valid, ready to submit?")
  }

  #GENERALIZATION:  Here are specific AWS INFO
  exists <- FALSE
  if(go){
    exists <- aws.s3::put_object(file = forecast_file,
                                 object = basename(forecast_file),
                                 bucket = fs::path("submissions", project_id),
                                 region= s3_region,
                                 base_url = s3_endpoint)
  }


  if(exists){
    message("Thank you for submitting!")
  }else{
    warning("Forecasts was not successfully submitted to server. Try again, then contact the Challenge organizers.")
  }
  return(invisible(exists))
}
