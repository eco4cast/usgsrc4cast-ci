library(tidyverse)
source("R/eco4cast-helpers/submit.R")
source("R/eco4cast-helpers/forecast_output_validator.R")
source("baseline_models/models/aquatics_persistence.R")

# 1. Load config and targets
config <- yaml::read_yaml("challenge_configuration.yaml")
targets <- readr::read_csv(
  config$target_groups$aquatics$targets_file,
  show_col_types = FALSE
)

# 2. Prepare obs dataframe for persistence_forecast()
obs <- targets |>
  filter(variable == "chla") |>
  select(site_id, time = datetime, chla = observation)

# 3. Run forecast for today only
today <- Sys.Date()
forecast_raw <- persistence_forecast(
  obs = obs,
  start_date_test = today,
  end_date_test = today,
  f_horizon = 35,
  n_members = 200
)

# 4. Convert to EFI standard format
forecast_efi <- forecast_raw |>
  filter(time > Sys.Date()) |>
  rename(datetime = time, reference_datetime = init_date) |>
  mutate(
    project_id = "usgsrc4cast",
    model_id = "persistence",
    duration = "P1D",
    family = "ensemble"
  ) |>
  select(
    project_id,
    model_id,
    datetime,
    reference_datetime,
    duration,
    site_id,
    family,
    parameter,
    variable,
    prediction
  )

# 5. Write and submit
file_date <- forecast_efi$reference_datetime[1]
forecast_file <- paste(
  "usgsrc4cast",
  file_date,
  "persistence.csv.gz",
  sep = "-"
)

write_csv(forecast_efi, forecast_file)

submit(
  forecast_file = forecast_file,
  project_id = "usgsrc4cast",
  metadata = NULL,
  ask = FALSE
)

unlink(forecast_file)
