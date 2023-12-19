

do_fetch_by_site <- function(file_out, site, pcodes, service, start_date, end_date) {
  message(file_out)
  fetch_by_pcode_service_by_site(
    site, pcodes, service,
    start_date, end_date) %>%
    write_csv(file = file_out)
  return(file_out)
}

do_alt_fetch_by_site <- function(file_out, site, alt_site, pcodes, service, start_date, end_date) {
  message(file_out)
  returned_data <- fetch_by_pcode_service_by_site(
    alt_site, pcodes, service,
    start_date, end_date) %>%
    {
      # Only attempt to add the alternative site no if there was data
      if(nrow(.) > 0)
        # The site number that was downloaded is actually our alternative site,
        # so add a column to retain that info, but substitute the site we are
        # actually using for metabolism modeling into `site_no`
        mutate(., alt_site_no = site_no) %>%
        mutate(site_no = site)
      else .
    } %>%
    write_csv(file = file_out)
  return(file_out)
}

fetch_by_pcode_service_by_site <- function(site, pcodes, service, start_date, end_date) {

  raw_data <- fetch_nwis_fault_tolerantly_bysite(site, pcodes, service, start_date, end_date)

  # Remove attributes, which typically have a timestamp associated
  #  with them this can cause strange rebuilds of downstream data,
  #   even if the data itself is the same.
  attr(raw_data, "comment") <- NULL
  attr(raw_data, "queryTime") <- NULL
  attr(raw_data, "headerInfo") <- NULL

  return(raw_data)
}

fetch_nwis_fault_tolerantly_bysite <- function(site, pcodes, service, start_date, end_date, max_tries = 10) {
  data_returned <- tryCatch(
    retry(readNWISdata(siteNumber = site,
                       parameterCd = pcodes,
                       startDate = start_date,
                       endDate = end_date,
                       service = service),
          until = function(val, cnd) "data.frame" %in% class(val),
          max_tries = max_tries),
    error = function(e) return()
  )

  # Noticed that some UV calls return a data.frame with a tz_cd column
  # and nothing else. These should be considered empty.
  # For example:
  # readNWISdata(siteNumber = "05579630", parameterCd = "00060", startDate = "2020-12-01",
  #              endDate = "2020-12-31", service = "uv")
  if(nrow(data_returned) == 0 & "tz_cd" %in% names(data_returned)) {
    return(data.frame())
  } else {
    return(data_returned)
  }
}



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
    # TODO: add in filter based on prvisional data or not?
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
    # TODO: add in filter based on prvisional data or not?
    filter(!is.na(chl_ug_L), chl_ug_L >= min_chl) %>%
    mutate(dateTime = as.Date(dateTime)) %>%
    group_by(site_no, dateTime) %>%
    summarise(chl_ug_L = mean(chl_ug_L), .groups = "drop")

  write_rds(x = daily_data, file = out_file)
  return(out_file)
}


aggregate_to_daily <- function(
    subdaily_data
){
  daily_data <- subdaily_data %>%
    group_by(siteNumbers, date) %>%
    summarise(.groups = "drop")

  return(daily_data)
}

