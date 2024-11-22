


download_historic_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    service,
    statCd = NULL,
    min_chl = 0, # minimum chlorohpyll-a to keep
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


download_historic_uv_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    service,
    min_chl = 0, # minimum chlorohpyll-a to keep
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

download_historic_uv_rfu_data <- function(
    sites,
    start_date,
    end_date,
    pcodes,
    service,
    min_chl = 0, # minimum chlorohpyll-a to keep
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
           #  14211010 is offset high by 0.5 ug/L
           chl_ug_L = case_when(site_no == "14211010" ~ chl_RFU * 4 - .5,
                                TRUE ~ chl_RFU * 4)) %>%
    group_by(site_no, dateTime) %>%
    summarise(chl_ug_L = mean(chl_ug_L), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}


