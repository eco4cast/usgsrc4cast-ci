library(tidyverse)
library(tsibble)
library(fable)
source('R/fablePersistenceModelFunction.R')

# 1.Read in the targets data
config <- yaml::read_yaml("challenge_configuration.yaml")
#'Read in target file.
targets <- readr::read_csv(config$target_groups$aquatics$targets_file,
                           show_col_types = F) %>%
  mutate(observation = ifelse(observation == 0 & variable == "chla", 0.00001, observation))

# 2. Make the targets into a tsibble with explicit gaps
targets_ts <- targets %>%
  as_tsibble(key = c('variable', 'site_id'), index = 'datetime') %>%
  # add NA values up to today (index)
  fill_gaps(.end = Sys.Date())

# 2. Run through each via map
# Requires a dataframe that has each of the variable in the RW_forecast function
site_var_combinations <- expand.grid(site = unique(targets$site_id),
                                     var = unique(targets$variable)) %>%
  # assign the transformation depending on the variable. chla and oxygen get a log(x) transformation
  mutate(transformation = ifelse(var %in% c('chla', 'oxygen'), 'log', 'none')) %>%
  mutate(boot_number = 200,
         h = 35,
         bootstrap = T,
         verbose = T)

# runs the RW forecast for each combination of variable and site_id
RW_forecasts <- purrr::pmap_dfr(site_var_combinations, RW_daily_forecast)

# convert the output into EFI standard
RW_forecasts_EFI <- RW_forecasts %>%
  rename(parameter = .rep,
         prediction = .sim) %>%
  # For the EFI challenge we only want the forecast for future
  filter(datetime > Sys.Date()) %>%
  group_by(site_id, variable) %>%
  mutate(reference_datetime = min(datetime) - lubridate::days(1),
         family = "ensemble",
         model_id = "persistenceRW") %>%
  select(model_id, datetime, reference_datetime, site_id, family, parameter, variable, prediction)

# 4. Write forecast file

file_date <- RW_forecasts_EFI$reference_datetime[1]

## TODO: does this need to be renamed?
forecast_file <- paste("aquatics", file_date, "persistenceRW.csv.gz", sep = "-")

RW_forecasts_EFI <- RW_forecasts_EFI |>
  filter(variable != "ch")

write_csv(RW_forecasts_EFI, forecast_file)

# TODO: need a new submission script
neon4cast::submit(forecast_file = forecast_file,
                  metadata = NULL,
                  ask = FALSE)

unlink(forecast_file)
