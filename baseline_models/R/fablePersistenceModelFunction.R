
# Function carry out a random walk forecast
RW_daily_forecast <- function(site, var, h,
                        bootstrap = FALSE, boot_number = 200,
                        transformation = 'none', verbose = TRUE,...) {
  # Work out when the forecast should start
  forecast_starts <- targets %>%
    dplyr::filter(!is.na(observation) & site_id == site & variable == var) %>%
    # Start the day after the most recent non-NA value
    dplyr::summarise(start_date = max(datetime) + lubridate::days(1)) %>% # Date
    dplyr::mutate(h = (Sys.Date() - start_date) + h) %>% # Horizon value
    dplyr::ungroup()

  if (verbose == T) {
    message(
      site,
      ' ',
      var,
      ' forecast with transformation = ',
      transformation,
      ' and bootstrap = ',
      bootstrap
    )
  }

  # filter the targets data set to the site_var pair
  targets_use <- targets %>%
    dplyr::filter(site_id == site,
           variable == var) %>%
    tsibble::as_tsibble(key = c('variable', 'site_id'), index = 'datetime') %>%
    # add NA values up to today (index)
    tsibble::fill_gaps(.end = Sys.Date()) %>%
    # Remove the NA's put at the end, so that the forecast starts from the last day with an observation,
    # rather than today
    dplyr::filter(datetime < forecast_starts$start_date)

  if (nrow(targets_use) == 0) {
    message('no targets available, no forecast run')
    empty_df <- data.frame('variable' = character(),
                            'site_id' = character(),
                            '.model' = character(),
                             'datetime' = lubridate::ymd(),
                            '.rep' = character(),
                            '.sim' = numeric())

    return(empty_df)

  } else {
    if (transformation == 'log') {
      RW_model <- targets_use %>%
        fabletools::model(RW = fable::RW(log(observation)))
    }
    if (transformation == 'log1p') {
      RW_model <- targets_use %>%
        fabletools::model(RW = fable::RW(log1p(observation)))
    }
    if (transformation == 'none') {
      RW_model <- targets_use %>%
        fabletools::model(RW = fable::RW(observation))
    }
    if (transformation == 'sqrt') {
      RW_model <- targets_use %>%
        fabletools::model(RW = fable::RW(sqrt(observation)))
    }

    if (bootstrap == T) {
      forecast <- RW_model %>% fabletools::generate(
          h = as.numeric(forecast_starts$h),
          bootstrap = T,
          times = boot_number
        )
    }  else
      forecast <- RW_model %>% fabletools::forecast(h = as.numeric(forecast_starts$h))
    message('forecast finished')
    return(forecast)
  }

}
