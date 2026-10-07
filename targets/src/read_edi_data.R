# Read manually-downloaded EDI package CSVs (see docs/add_cadwr_cdec_sites.md)
# and aggregate the 15-min chlorophyll fluorescence series to daily means. This
# is the EDI (best-QA/QC) layer of the EDI > WDL > CDEC source stack for the CA
# DWR Delta sites; it feeds the one-time S3 historical backfill, not the daily
# pipeline (EDI records end 2024/2025, before the recurring trailing window).
#
# Two EDI packages cover our DWR sites. Both report chlorophyll fluorescence in
# ug/L, confirmed from each package's EML:
#   - edi.2180.2 (NCRO): one CSV per station, {STN}_POR.csv, wide columns with a
#     "Chlorophyll" column and "Date_Time" as MM/DD/YYYY HH:MM:SS. Covers GLE,
#     MHO, OH1 among our sites.
#   - edi.1177.8 (EMP): SJR_data.csv, chlorophyll in the "fluorescence" column,
#     with separate "date" (YYYY-MM-DD) and "time" columns. Covers SJR.
# MLS is in neither package (installed Jun 2024) and stays CDEC-only.
#
# Data in both packages are pre-validated (values failing QA/QC are set to NA),
# so we only need to drop NA / negative values and average to a daily mean.

# Read one NCRO (edi.2180.2) per-station POR file -> daily mean chla.
# Returns tibble(site_no, dateTime, chl_ug_L), matching download_cdec_chla_data.
read_edi_ncro_chla <- function(file, min_chl = 0) {
  readr::read_csv(file, show_col_types = FALSE, progress = FALSE,
                  col_types = readr::cols(.default = readr::col_character())) |>
    dplyr::transmute(
      site_no = Station_Code,
      dateTime = as.Date(Date_Time, format = "%m/%d/%Y %H:%M:%S"),
      value = suppressWarnings(as.numeric(Chlorophyll))
    ) |>
    dplyr::filter(!is.na(dateTime), !is.na(value), value >= min_chl) |>
    dplyr::group_by(site_no, dateTime) |>
    dplyr::summarise(chl_ug_L = mean(value), .groups = "drop")
}

# Read the EMP (edi.1177.8) SJR file -> daily mean chla.
# Returns tibble(site_no, dateTime, chl_ug_L), matching download_cdec_chla_data.
read_edi_emp_chla <- function(file, min_chl = 0) {
  readr::read_csv(file, show_col_types = FALSE, progress = FALSE,
                  col_types = readr::cols(.default = readr::col_character())) |>
    dplyr::transmute(
      site_no = station,
      dateTime = as.Date(date),
      value = suppressWarnings(as.numeric(fluorescence))
    ) |>
    dplyr::filter(!is.na(dateTime), !is.na(value), value >= min_chl) |>
    dplyr::group_by(site_no, dateTime) |>
    dplyr::summarise(chl_ug_L = mean(value), .groups = "drop")
}

# Build the full EDI daily chla record for all covered DWR sites, formatted to
# the challenge target schema (project_id, site_id, datetime, duration,
# variable, observation) with DWR-{station} site_ids.
#
# `edi_dir` is the directory holding the extracted packages (e.g. targets/in),
# expected to contain edi.2180.2/ and edi.1177.8/ subdirectories.
build_edi_chla <- function(edi_dir, min_chl = 0) {
  ncro_files <- c(
    GLE = file.path(edi_dir, "edi.2180.2", "GLE_POR.csv"),
    MHO = file.path(edi_dir, "edi.2180.2", "MHO_POR.csv"),
    OH1 = file.path(edi_dir, "edi.2180.2", "OH1_POR.csv")
  )
  emp_files <- c(
    SJR = file.path(edi_dir, "edi.1177.8", "SJR_data.csv")
  )

  ncro <- purrr::map(ncro_files, read_edi_ncro_chla, min_chl = min_chl) |>
    purrr::list_rbind()
  emp <- purrr::map(emp_files, read_edi_emp_chla, min_chl = min_chl) |>
    purrr::list_rbind()

  dplyr::bind_rows(ncro, emp) |>
    dplyr::transmute(
      project_id = "usgsrc4cast",
      site_id = paste0("DWR-", site_no),
      datetime = dateTime,
      duration = "P1D",
      variable = "chla",
      observation = chl_ug_L
    ) |>
    dplyr::arrange(site_id, datetime)
}

# Read authoritative station metadata (name + coordinates) from the local EDI
# packages for the DWR sites they cover: GLE/MHO/OH1 from the NCRO package
# (edi.2180.2 StationsMetadata.csv) and SJR from the EMP package
# (edi.1177.8 StationMetadata_EDI_2026.csv). MLS is in neither package and must
# be sourced elsewhere (CDEC). EDI supplies only station_nm/latitude/longitude;
# challenge-specific fields (agency_cd, site_url, project_id, ...) are added by
# the caller. Station names are title-cased since EDI stores them upper-case.
#
# Returns tibble(site_no, station_nm, latitude, longitude) with site_no = the
# CDEC/EDI station code (e.g. "OH1").
build_edi_site_metadata <- function(edi_dir) {
  ncro_meta <- readr::read_csv(
    file.path(edi_dir, "edi.2180.2", "StationsMetadata.csv"),
    show_col_types = FALSE, progress = FALSE
  ) |>
    dplyr::filter(Station_Code %in% c("GLE", "MHO", "OH1")) |>
    dplyr::transmute(site_no = Station_Code,
                     station_nm = stringr::str_to_title(Station_Name),
                     latitude = Latitude,
                     longitude = Longitude)

  emp_meta <- readr::read_csv(
    file.path(edi_dir, "edi.1177.8", "StationMetadata_EDI_2026.csv"),
    show_col_types = FALSE, progress = FALSE
  ) |>
    dplyr::filter(station == "SJR") |>
    dplyr::transmute(site_no = station,
                     station_nm = stringr::str_to_title(description),
                     latitude = latitude,
                     longitude = longitude)

  dplyr::bind_rows(ncro_meta, emp_meta)
}
