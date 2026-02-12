
#' Persistence forecast: predict last observed value for all lead times
#'
#' @param obs dataframe with columns: site_id, time, chla
#' @param start_date_test start of test period (character or Date)
#' @param end_date_test end of test period (character or Date)
#' @param f_horizon forecast horizon in days (e.g., 11 for days 0-10)
#' @param n_members number of ensemble members to generate (default 200)
#' @return dataframe with site_id, init_date, lead_time, time, model_id, parameter, variable, prediction
persistence_forecast <- function(obs, start_date_test, end_date_test, f_horizon, n_members = 200) {

  start_date <- as.Date(start_date_test)
  end_date <- as.Date(end_date_test)
  init_dates <- seq(start_date, end_date, by = "1 day")
  lead_times <- 0:(f_horizon - 1)

  obs_clean <- obs |>
    filter(!is.na(chla), chla > 0) |>
    arrange(site_id, time)

  sites <- unique(obs_clean$site_id)

  # Estimate per-site innovation sd from historical log-differences
  # Only use data before test period
  obs_pre <- obs_clean |> filter(time < start_date)

  innov_sds <- obs_pre |>
    group_by(site_id) |>
    arrange(time) |>
    mutate(
      dt = as.numeric(difftime(time, lag(time), units = "days")),
      log_diff = log(chla) - lag(log(chla))
    ) |>
    filter(!is.na(dt), dt > 0, dt <= 30) |>
    mutate(innov = log_diff / sqrt(dt)) |>
    summarise(innov_sd = sd(innov, na.rm = TRUE), .groups = "drop")

  # Pooled fallback for sites with insufficient data
  pooled_sd <- sd(
    (obs_pre |>
       group_by(site_id) |>
       arrange(time) |>
       mutate(
         dt = as.numeric(difftime(time, lag(time), units = "days")),
         log_diff = log(chla) - lag(log(chla))
       ) |>
       filter(!is.na(dt), dt > 0, dt <= 30) |>
       mutate(innov = log_diff / sqrt(dt)))$innov,
    na.rm = TRUE
  )

  innov_sds <- innov_sds |>
    mutate(innov_sd = ifelse(is.na(innov_sd) | innov_sd == 0, pooled_sd, innov_sd))

  results <- vector("list", length(sites))

  for (i in seq_along(sites)) {
    site <- sites[i]
    site_obs <- obs_clean |> filter(site_id == site)
    obs_times <- site_obs$time
    obs_vals <- site_obs$chla
    site_innov_sd <- innov_sds |> filter(site_id == site) |> pull(innov_sd)

    if (length(obs_times) == 0 || length(site_innov_sd) == 0) next

    site_results <- vector("list", length(init_dates))

    for (j in seq_along(init_dates)) {
      init_date <- init_dates[j]

      # Find most recent observation strictly before init_date
      # (forecast issued on init_date cannot use that day's observation)
      idx <- findInterval(init_date - 1, obs_times)
      if (idx == 0) next  # no observation before this init_date

      last_val <- obs_vals[idx]
      log_last <- log(last_val)
      gap <- as.numeric(init_date - obs_times[idx])

      # Generate independent ensemble samples per lead time
      # Each lead time is drawn independently centered on last_val (persistence)
      ensemble_list <- vector("list", length(lead_times))

      for (lt_idx in seq_along(lead_times)) {
        lt <- lead_times[lt_idx]
        total_time <- gap + lt

        if (total_time == 0) {
          samples <- rep(last_val, n_members)
        } else {
          forecast_sd <- site_innov_sd * sqrt(total_time)
          # Bias correction so E[prediction] = last_val (true persistence)
          samples <- exp(rnorm(n_members, mean = log_last - forecast_sd^2 / 2, sd = forecast_sd))
        }

        ensemble_list[[lt_idx]] <- tibble(
          site_id = site,
          init_date = init_date,
          lead_time = lt,
          time = init_date + lt,
          model_id = "persistence",
          parameter = as.character(seq_len(n_members)),
          variable = "chla",
          prediction = samples
        )
      }

      site_results[[j]] <- bind_rows(ensemble_list)
    }

    results[[i]] <- bind_rows(site_results)
  }

  bind_rows(results)
}
