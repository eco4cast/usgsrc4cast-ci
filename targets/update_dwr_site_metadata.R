# Refresh the DWR site metadata rows in the repo-root USGS_site_metadata.csv
# from the authoritative EDI station metadata downloaded under targets/in/.
#
# See docs/add_cadwr_cdec_sites.md. Only station_nm / latitude / longitude are
# updated (the only fields EDI provides); challenge-specific columns
# (agency_cd, site_url, project_id, colocated, queryTime) are left as-is. The
# four EDI-covered sites (DWR-GLE, DWR-MHO, DWR-OH1, DWR-SJR) are refreshed;
# DWR-MLS is not in EDI and its CDEC-sourced coordinates are preserved. USGS
# rows are untouched.
#
# This fixes, among other things, the DWR-OH1 longitude, which was hand-entered
# ~21 km off (-121.5742 vs the EDI value -121.3312).
#
# Run from the targets/ directory:
#   Rscript update_dwr_site_metadata.R

suppressMessages(library(tidyverse))

source("src/read_edi_data.R")

meta_file <- "../USGS_site_metadata.csv"
edi_dir <- "in"

meta <- read_csv(meta_file, show_col_types = FALSE)
edi_meta <- build_edi_site_metadata(edi_dir) |>
  mutate(site_id = paste0("DWR-", site_no)) |>
  select(site_id, edi_station_nm = station_nm,
         edi_latitude = latitude, edi_longitude = longitude)

updated <- meta |>
  left_join(edi_meta, by = "site_id") |>
  mutate(
    station_nm = coalesce(edi_station_nm, station_nm),
    latitude   = coalesce(edi_latitude, latitude),
    longitude  = coalesce(edi_longitude, longitude)
  ) |>
  select(-edi_station_nm, -edi_latitude, -edi_longitude)

# Report what changed.
changed <- meta |>
  select(site_id, old_nm = station_nm, old_lat = latitude, old_lon = longitude) |>
  inner_join(
    updated |> select(site_id, new_nm = station_nm,
                       new_lat = latitude, new_lon = longitude),
    by = "site_id"
  ) |>
  filter(old_nm != new_nm | old_lat != new_lat | old_lon != new_lon)

message("Rows updated from EDI: ", nrow(changed))
if (nrow(changed) > 0) print(as.data.frame(changed))

if (nrow(updated) != nrow(meta)) {
  stop("Row count changed (", nrow(meta), " -> ", nrow(updated),
       "); the update must not add or drop sites.")
}

write_csv(updated, meta_file)
message("\nWrote ", normalizePath(meta_file))
