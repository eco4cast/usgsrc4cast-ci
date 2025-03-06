

#' Download Historic Chlorophyll Data
#'
#' This function retrieves historic chlorophyll data from the NWIS database for specified sites
#' and date ranges, filters by a minimum chlorophyll concentration, and outputs the data as an RDS file.
#'
#' @param sites A character vector of site numbers for which to download data.
#' @param start_date The start date for the data retrieval in 'YYYY-MM-DD' format.
#' @param end_date The end date for the data retrieval in 'YYYY-MM-DD' format.
#' @param pcodes A character vector of parameter codes for the data to be retrieved.
#' @param service A character string specifying the data service to use (e.g., "dv").
#' @param statCd An optional character string for the statistic code to filter the data.
#' @param min_chl A numeric value specifying the minimum chlorophyll concentration (in µg/L) to retain in the output. Default is 0.
#' @param out_file A character string indicating the path to the output RDS file where the data will be saved.
#'
#' @return A character string indicating the path to the saved RDS file.
#' @export
download_historic_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    service,
    statCd = NULL,
    min_chl = 0, # minimum chlorohpyll to keep
    out_file
){

  daily_data <- dataRetrieval::readNWISdata(siteNumbers = sites,
                                            parameterCd = pcodes,
                                            startDate = start_date,
                                            endDate = end_date,
                                            service = service,
                                            statCd = statCd) %>%
    pivot_longer(cols = matches(paste0(statCd, "$")),
                 names_to = "parameter_name",
                 values_to = "chl_ug_L") %>%
    select(site_no, dateTime, parameter_name, chl_ug_L) %>%
    filter(!is.na(chl_ug_L), chl_ug_L >= min_chl) %>%
    mutate(dateTime = as.Date(dateTime)) %>%
    group_by(site_no, dateTime) %>%
    summarise(chl_ug_L = mean(chl_ug_L), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}

#' Download Historic Chlorophyll UV Data
#'
#' This function retrieves historic chlorophyll UV data from the NWIS database for specified sites
#' and date ranges, filters by a minimum chlorophyll concentration, and outputs the data as an RDS file.
#'
#' @param sites A character vector of site numbers for which to download data.
#' @param start_date The start date for the data retrieval in 'YYYY-MM-DD' format.
#' @param end_date The end date for the data retrieval in 'YYYY-MM-DD' format.
#' @param pcodes A character vector of parameter codes for the data to be retrieved.
#' @param service A character string specifying the data service to use (e.g., "uv").
#' @param min_chl A numeric value specifying the minimum chlorophyll concentration (in µg/L) to retain in the output. Default is 0.
#' @param out_file A character string indicating the path to the output RDS file where the data will be saved.
#'
#' @return A character string indicating the path to the saved RDS file.
#' @export
download_historic_uv_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    service,
    min_chl = 0, # minimum chlorohpyll to keep
    out_file
){

  daily_data <- dataRetrieval::readNWISdata(siteNumbers = sites,
                                            parameterCd = pcodes,
                                            startDate = start_date,
                                            endDate = end_date,
                                            service = service) %>%
    pivot_longer(cols = matches("00000$"),
                 names_to = "parameter_name",
                 values_to = "chl_ug_L") %>%
    select(site_no, dateTime, parameter_name, chl_ug_L) %>%
    filter(!is.na(chl_ug_L), chl_ug_L >= min_chl) %>%
    mutate(dateTime = as.Date(dateTime)) %>%
    group_by(site_no, dateTime) %>%
    summarise(chl_ug_L = mean(chl_ug_L), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}

#' Download Historic Chlorophyll RFU Data
#'
#' This function retrieves historic chlorophyll RFU data from the NWIS database for specified sites
#' and date ranges, applies a conversion to chlorophyll concentration, filters by a minimum value,
#' and outputs the data as an RDS file.
#'
#' @param sites A character vector of site numbers for which to download data.
#' @param start_date The start date for the data retrieval in 'YYYY-MM-DD' format.
#' @param end_date The end date for the data retrieval in 'YYYY-MM-DD' format.
#' @param pcodes A character vector of parameter codes for the data to be retrieved.
#' @param service A character string specifying the data service to use (e.g., "uv").
#' @param min_chl A numeric value specifying the minimum chlorophyll concentration (in µg/L) to retain in the output. Default is 0.
#' @param out_file A character string indicating the path to the output RDS file where the data will be saved.
#'
#' @return A character string indicating the path to the saved RDS file.
#' @export
download_historic_uv_rfu_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    service,
    min_chl = 0, # minimum chlorohpyll to keep
    out_file
){

  daily_data <- dataRetrieval::readNWISdata(siteNumbers = sites,
                                            parameterCd = pcodes,
                                            startDate = start_date,
                                            endDate = end_date,
                                            service = service) %>%
    pivot_longer(cols = matches("00000$"),
                 names_to = "parameter_name",
                 values_to = "chl_RFU") %>%
    select(site_no, dateTime, parameter_name, chl_RFU) %>%
    filter(!is.na(chl_RFU), chl_RFU >= min_chl) %>%
    mutate(dateTime = as.Date(dateTime),
           # multiplying by factor of 4 will be sufficient in most cases
           #  14211010 is offset high by 0.2 ug/L
           chl_ug_L = case_when(site_no == "14211010" ~ chl_RFU * 4 - .2,
                                TRUE ~ chl_RFU * 4),
           chl_ug_L = ifelse(chl_ug_L < 0, 0, chl_ug_L)) %>%
    group_by(site_no, dateTime) %>%
    summarise(chl_ug_L = mean(chl_ug_L), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}


