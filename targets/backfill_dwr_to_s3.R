# One-time backfill for the CA DWR sites: EDI deep history + a CDEC fill from
# where EDI ends through today. See docs/add_cadwr_cdec_sites.md.
#
# Source precedence is EDI > CDEC (WDL skipped for now). For each EDI-covered
# site (GLE/MHO/OH1/SJR) the EDI record is authoritative and CDEC only fills the
# days after EDI's coverage ends. MLS is not on EDI, so its entire record comes
# from CDEC. The result replaces the DWR rows in the S3 historic targets file;
# USGS rows are untouched.
#
# This DELIBERATELY DOES NOT PUSH to S3 — it writes the merged file to out/ for
# inspection before a separate, explicit upload step. Run from targets/:
#   Rscript backfill_dwr_to_s3.R

suppressMessages(library(tidyverse))

source("src/read_edi_data.R")
source("src/download_cdec_data.R")

config   <- yaml::read_yaml("../challenge_configuration.yaml")
edi_dir  <- "in"
out_file <- "out/historic_data_dwr_backfilled.csv"
today    <- Sys.Date()
mls_floor <- as.Date("2020-01-01")   # MLS installed Jun 2024; floor is a safe lower bound

# --- EDI deep history (GLE/MHO/OH1/SJR) ------------------------------------
edi <- build_edi_chla(edi_dir)
edi_end <- edi |>
  group_by(site_id) |>
  summarise(edi_last = max(datetime), .groups = "drop")
message("EDI coverage ends:")
print(as.data.frame(edi_end))

# --- CDEC fill: per-site start = day EDI ends (EDI wins the overlap) --------
# MLS has no EDI, so it starts at the floor and CDEC covers its whole record.
stations <- c("SJR", "MLS", "GLE", "MHO", "OH1")
starts <- tibble(station = stations, site_id = paste0("DWR-", stations)) |>
  left_join(edi_end, by = "site_id") |>
  mutate(cdec_start = coalesce(edi_last, mls_floor))
message("\nCDEC pull windows:")
print(as.data.frame(starts |> select(station, cdec_start) |> mutate(cdec_end = today)))

cdec <- pmap(list(starts$station, starts$cdec_start), function(stn, st) {
  Sys.sleep(3)  # be gentle with the CDEC servlet between stations
  f <- download_cdec_chla_data(
    stations = stn, start_date = st, end_date = today,
    sensor_num = 28, dur_code = "E", out_file = tempfile(fileext = ".rds")
  )
  read_rds(f)
}) |>
  list_rbind()

cdec_fmt <- cdec |>
  transmute(project_id = "usgsrc4cast",
            site_id = paste0("DWR-", site_no),
            datetime = dateTime,
            duration = "P1D",
            variable = "chla",
            observation = chl_ug_L)

# EDI > CDEC: drop CDEC rows on any (site, day) EDI already covers.
cdec_fill <- anti_join(cdec_fmt, edi, by = c("site_id", "datetime"))
message("\nCDEC daily rows pulled: ", nrow(cdec_fmt),
        " | kept after EDI precedence: ", nrow(cdec_fill))

dwr <- bind_rows(edi, cdec_fill) |> arrange(site_id, datetime)

message("\nFull DWR record (EDI + CDEC fill):")
dwr |>
  mutate(src = if_else(paste(site_id, datetime) %in%
                         paste(edi$site_id, edi$datetime), "EDI", "CDEC")) |>
  group_by(site_id) |>
  summarise(n = n(), first = min(datetime), last = max(datetime),
            edi = sum(src == "EDI"), cdec = sum(src == "CDEC"), .groups = "drop") |>
  as.data.frame() |> print()

# --- Merge into S3 historic (DWR replaced, USGS untouched) ------------------
s3_url <- config$target_groups$aquatics$targets_file
message("\nReading current S3 historic file: ", s3_url)
s3 <- read_csv(s3_url, show_col_types = FALSE)

combined <- bind_rows(
  anti_join(s3, dwr, by = c("site_id", "datetime")),
  dwr
) |>
  arrange(site_id, datetime)

usgs_before <- sum(!startsWith(s3$site_id, "DWR-"))
usgs_after  <- sum(!startsWith(combined$site_id, "DWR-"))
if (usgs_before != usgs_after) {
  stop("USGS row count changed (", usgs_before, " -> ", usgs_after,
       "); backfill must not touch non-DWR sites.")
}

message("\nCombined rows: ", nrow(combined),
        " (S3 had ", nrow(s3), "; DWR rows now ",
        sum(startsWith(combined$site_id, "DWR-")), ")")

write_csv(combined, out_file)
message("\nWrote merged file (NOT pushed to S3): ", normalizePath(out_file))
message("Inspect it, then push separately if it looks correct.")
