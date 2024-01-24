#'# Ecological Forecasting Initiative Null Model

#'## Set-up
print(paste0("Running Creating Daily Terrestrial Forecasts at ", Sys.time()))

#' Required packages.
#' EFIstandards is at remotes::install_github("eco4cast/EFIstandards")
library(tidyverse)
library(lubridate)
library(aws.s3)
library(jsonlite)
library(imputeTS)
#' set the random number for reproducible MCMC runs
set.seed(329)

config <- yaml::read_yaml("challenge_configuration.yaml")

#'Team name code
team_name <- "climatology"

#'Read in target file.
targets <- readr::read_csv(config$target_groups$aquatics$targets_file,
                           show_col_types = F)

sites <- readr::read_csv(paste0("https://github.com/eco4cast/usgsrc4cast-ci/",
                                "raw/prod/USGS_site_metadata.csv"),
                         show_col_types = F)

# calculates a doy average for each target variable in each site
target_clim <- targets %>%
  mutate(doy = yday(datetime),
         year = year(datetime)) %>%
  filter(year < year(Sys.Date())) |>
  group_by(doy, site_id, variable) %>%
  summarise(mean = mean(observation, na.rm = TRUE),
            sd = sd(observation, na.rm = TRUE),
            .groups = "drop") %>%
  mutate(mean = ifelse(is.nan(mean), NA, mean))

#curr_month <- month(Sys.Date())
curr_month <- month(Sys.Date())
if(curr_month < 10){
  curr_month <- paste0("0", curr_month)
}


curr_year <- year(Sys.Date())
start_date <- Sys.Date() + days(1)

forecast_dates <- seq(start_date, as_date(start_date + days(34)), "1 day")
forecast_doy <- yday(forecast_dates)

forecast_dates_df <- tibble(datetime = forecast_dates,
                            doy = forecast_doy)

forecast <- target_clim %>%
  mutate(doy = as.integer(doy)) %>%
  filter(doy %in% forecast_doy) %>%
  full_join(forecast_dates_df, by = 'doy') %>%
  arrange(site_id, datetime)

subseted_site_names <- unique(forecast$site_id)
site_vector <- NULL
for(i in 1:length(subseted_site_names)){
  site_vector <- c(site_vector, rep(subseted_site_names[i], length(forecast_dates)))
}

forecast_tibble <- tibble(datetime = rep(forecast_dates, length(subseted_site_names)),
                           site_id = site_vector,
                           variable = "chla")

forecast <- right_join(forecast, forecast_tibble)

forecast |>
  ggplot(aes(x = datetime, y = mean)) +
  geom_point() +
  facet_grid(site_id ~ variable, scale = "free")

combined <- forecast %>%
  select(datetime, site_id, variable, mean, sd) %>%
  group_by(site_id, variable) %>%
  # remove rows where all in group are NA
  filter(all(!is.na(mean))) %>%
  # retain rows where group size >= 2, to allow interpolation
  filter(n() >= 2) %>%
  mutate(mu = imputeTS::na_interpolation(mean),
         sigma = median(sd, na.rm = TRUE)) %>%
  pivot_longer(c("mu", "sigma"),names_to = "parameter", values_to = "prediction") |>
  mutate(family = "normal") |>
  ungroup() |>
  mutate(reference_datetime = lubridate::as_date(min(datetime)) - lubridate::days(1),
         model_id = "climatology") |>
  select(model_id, datetime, reference_datetime, site_id, family, parameter, variable, prediction)

combined |>
  filter(parameter == "mu") |>
  ggplot(aes(x = datetime, y = prediction)) +
  geom_point() +
  facet_grid(site_id ~ variable, scale = "free")


# plot the forecasts
combined %>%
  select(datetime, prediction ,parameter, variable, site_id) %>%
  pivot_wider(names_from = parameter, values_from = prediction) %>%
  ggplot(aes(x = datetime)) +
  geom_ribbon(aes(ymin=mu - sigma*1.96, ymax=mu + sigma*1.96), alpha = 0.1) +
  geom_line(aes(y = mu)) +
  facet_grid(variable~site_id, scales = "free") +
  theme_bw()

file_date <- combined$reference_datetime[1]

forecast_file <- paste("aquatics", file_date, "climatology.csv.gz", sep = "-")

write_csv(combined, forecast_file)

### probably need a different way to submit;
neon4cast::submit(forecast_file = forecast_file,
                  ask = FALSE)

unlink(forecast_file)


