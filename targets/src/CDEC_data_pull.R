# Download CDEC station data from sites in the south delta
# Created by: Crystal Sturgeon
# Date Created: 6/3/24
# Date Last Modified: 6/3/24

## LIBRARIES ----------
#library(tidyverse)
#library(lubridate)
#library(scales)
#library(gt)
#library(data.table)
#library(ggplot2)
library(cder)
library(here)
library(readxl)
library(tidyverse)

## Continuous data CDEC is obtained using cder package https://CRAN.R-project.org/package=cder 



# Site List -----
# 6/7/24- NF - included NCRO sites from DWR_NCRO_south_delta_data_pull.R since this database did not have river stage, flow, or velocity data for these sites, so I'm including them in this data pull for the sake of the gap analysis, although pulling from CNRA database with the other script is preferable since this data has been better QA'd.
site_list1 <-  c("HBP",
                "CLC",
                "HRO",
                "KA0",
                "TRP")

site_list2 <- c("VIC",
                "MTB",
                "MAB",
                "MHR",
                "MRB")

site_list3 <- c("ISH",
                "OH4",
                "CIS",
                "GCF",
                "OLD")

site_list4 <- c("OBD",
                "PCO",
                "SUR",
                "TPS",
                "JTR")

site_list5 <- c("OMR",
                "MSD",
                "SJL",
                "UNI",
                "MMB")

site_list6 <- c("MDM",
                "OBI",
                "GCT",
                "GLE",
                "DGL")

site_list7 <- c("WCI",
                "ORI",
                "OAD",
                "ORM",
                "ORX")

site_list8 <- c("OH1",
                "PDC",
                "PDU",
                "SGA",
                "TPI")

site_list9 <- c("MUP",
                "MRX",
                "MHO",
                "MRU",
                "SJD")


site_list <- c("HBP",
              "CLC",
              "HRO",
              "KA0",
              "TRP",
              "VIC",
              "MTB",
              "MAB",
              "MHR",
              "MRB",
              "ISH",
              "OH4",
              "CIS",
              "GCF",
              "OLD",
              "OBD",
              "PCO",
              "SUR",
              "TPS",
              "JTR",
              "OMR",
              "MSD",
              "SJL",
              "UNI",
              "MMB",
              "MDM",
              "OBI",
              "GCT",
              "GLE",
              "DGL",
              "WCI",
              "ORI",
              "OAD",
              "ORM",
              "ORX",
              "OH1",
              "PDC",
              "PDU",
              "SGA",
              "TPI",
              "MUP",
              "MRX",
              "MHO",
              "MRU",
              "SJD")

# Metadata -------
cdec_meta("HBP")

#USBR <- c("VIC", "UNI")
#DWR_SCRO <- c("MRB")
#USGS <- c("OH4", "MDM", "OBI")
#DWR_DISE <- c("MSD")
#DWR <- c("TPI", "GCT")
#DWR_OM <- c("HBP", "CLC", "HRO", "KA0", "TRP", "OLD", "OMR")
#DWR_NCRO <- c("MTB", "MAB", "MHR", "ISH", "CIS", "GCF", "OBD", "PCO", "SUR", "TPS", "JTR", "SJL", "MMB", "GLE", "DGL", "WCI", "ORI", "OAD", "ORM", "ORX", "OH1", "PDC", "PDU", "SGA", "MUP", "MRX", "MHO", "MRU", "SJD")

  
cdec_sensors <- read_excel(here("Data","Data_raw","CDEC_sensors.xlsx"))

sensor_list <- cdec_sensors %>% 
  filter(keep_Y_N == "y") %>% 
  pull(as.numeric(`SENSOR NUM`))
            
duration_list <- c("event","hourly","monthly")



# Param List ------
# sensor type list (selecting parameters we're interested in)
parameter_list <- c("BLUE GA", 
                    "CHLORPH", 
                    "DIS OXY",
                    "DOXY 3M",
                    "DOXY 6M",
                    "DSOXSAT", 
                    "EL COND",
                    "EL CND",
                    "EL CONDB",
                    "FDOM", 
                    "FLUORO",
                    "FLURFUB",
                    "pH mV", 
                    "PH VAL", 
                    "TEMP W", 
                    "TEMPW C", 
                    "TURB W",
                    "TURB WF",
                    "D ORGCO",
                    "D ORGCA",
                    "D ORGCZ",
                    "Diss Br", 
                    "Diss Cl", 
                    "DissNO3", 
                    "DissSO4",
                    "DissPO4",
                    "T ORG C",
                    "T ORGCZ",
                    "OUTFLWV",
                    "VLOCITY",
                    "PCYANIN",
                    "PCYRFUB",
                    "RIV STG",
                    "RIVST88",
                    "FLOW")

start.date = "2012-10-01"
end.date = Sys.Date()



# Data pull ------
# the cdec_query function isn't working with >35 stations in the station name vector, so I split it up into two lists and corresponding cdec_query's

# Hourly data
site_list_names_hourly1 <- list()

for (i in site_list)
{
  x <- cdec_query(i, sensor_list, "hourly", start.date, end.date)
  
  assign(paste0(i, "_hourly_data1"), x)
  
  site_list_names_hourly1[[paste0(i, "_hourly_data1")]] <- x
}


# Event data
site_list_names_event <- list()

for (i in site_list)
{
  x <- cdec_query(i, sensor_list, "event", start.date, end.date)
  
  assign(paste0(i, "_event_data"), x)
  
  site_list_names_event[[paste0(i, "_event_data")]] <- x
}

#cdec_monthly_data <- cdec_query(site_list,
                              #sensor_list,
                              #"monthly",
                              #start.date,
                              #end.date)
# no monthly data values for these sensors at these stations during these dates

# we don't need daily average data but the code for that is below
#cdec_daily_data <- cdec_query(site_list,
#                                sensor_list,
#                                "daily",
#                                start.date,
#                                end.date)





# Bind Data -------
# Event data seems to have the finest resolution, thus we will keep this for our gap analysis table, every time a station has daily data, it also either has hourly or event data, thus we'll just keep the hourly and event dataframes

# binding rows of hourly data
cdec_data1 <- bind_rows(site_list_names_hourly1, .id = "id")

# binding rows of event (15-min data)
cdec_data2 <- bind_rows(site_list_names_event, .id = "id")

# binding hourly and event data
cdec_data <- bind_rows(cdec_data1, cdec_data2)



#looking for duplicated rows between hourly and event datasets
dups <- cdec_data %>% 
  distinct(SensorType, StationID, id) %>% 
  group_by(SensorType, StationID) %>% 
  summarise(duplicates = paste(id, collapse = ", ")) %>% 
  ungroup()

# removing hourly data when event data is available for that site
cdec_data_final <- cdec_data %>% 
  filter(case_when(
    SensorType == "RIV STG" ~ id != "DGL_hourly_data1",
    StationID == "MDM" ~ id != "MDM_hourly_data1",
    StationID == "MSD" & SensorType %in% c("BAT VOL", "CHLORPH", "DIS OXY", "EL COND", "PH VAL", "RIV STG", "TEMP W", "TURB W") ~ id != "MSD_hourly_data1",
    SensorType == "BAT VOL" ~ id != "MTB_hourly_data1",
    SensorType == "EL COND" ~ id != "MTB_hourly_data1",
    StationID == "OBI" ~ id != "OBI_hourly_data1",
    StationID == "OH4" ~ id != "OH4_hourly_data1",
    SensorType == "RIV STG" ~ id != "OLD_hourly_data1",
    SensorType == "BLUE GA" | SensorType == "FDOM" ~ id != "TRP_hourly_data1",
    SensorType == "EL COND" ~ id != "UNI_hourly_data1",
    SensorType == "EL COND" ~ id != "VIC_hourly_data1"
  ))

cdec_data_final <- cdec_data %>% 
  filter(
    !( (SensorType == "RIV STG" & id == "DGL_hourly_data1") |
       (StationID == "MDM" & id == "MDM_hourly_data1") |
       (StationID == "MSD" & SensorType %in% c("BAT VOL", "CHLORPH", "DIS OXY", "EL COND", "PH VAL", "RIV STG", "TEMP W", "TURB W") & id == "MSD_hourly_data1") |
       (SensorType == "BAT VOL" & id == "MTB_hourly_data1") |
       (SensorType == "EL COND" & id == "MTB_hourly_data1") |
       (StationID == "OBI" & id == "OBI_hourly_data1") |
       (StationID == "OH4" & id == "OH4_hourly_data1") |
       (SensorType == "RIV STG" & id == "OLD_hourly_data1") |
       (SensorType %in% c("BLUE GA", "FDOM") & id == "TRP_hourly_data1") |
       (SensorType == "EL COND" & id == "UNI_hourly_data1") |
       (SensorType == "EL COND" & id == "VIC_hourly_data1") )
  )


# checking that this worked
dups_final <- cdec_data_final %>% 
  distinct(SensorType, StationID, id) %>% 
  group_by(SensorType, StationID) %>% 
  summarise(duplicates = paste(id, collapse = ", ")) %>% 
  ungroup()



# saving this data
saveRDS(cdec_data_final, paste0("Data/Data_raw/cdec_full_data_", Sys.Date(), ".rds"))

cdec_data_final <- readRDS("Data/Data_raw/cdec_full_data_2024-06-07.rds")



# Filter Relevant Rows -------
dat <- cdec_data %>% 
  filter(SensorType %in% parameter_list)




# Samp Freq and Size -------
# calculating sampling frequency for each station/parameter combo
intervals_cdec <- dat %>% 
  rename(parameter = SensorType, station = StationID, DT = DateTime) %>% 
  group_by(parameter, station) %>% 
  mutate(DT = ymd_hms(DT)) %>% 
  mutate(dt_lag = lag(DT)) %>% 
  summarise(median_samp_freq = median(as.numeric(difftime(DT, dt_lag, units = "mins")), na.rm = TRUE)) %>%
  mutate(samp_freq_units = "min") %>% 
  select(station, parameter, median_samp_freq, samp_freq_units)



# dataset of emp data counts for each parameter & site combo
cdec_samp_count <- dat %>% 
  rename(station = StationID, parameter = SensorType) %>% 
  group_by(station, parameter) %>% 
  summarise(n = n())


cdec_param <- dat %>% 
  rename(parameter = SensorType, station = StationID, DT = DateTime) %>% 
  mutate(DT = date(DT)) %>%
  rename(sample_date = DT) %>%
  group_by(parameter, station) %>% 
  summarise(date_min = min(sample_date), date_max = max(sample_date)) %>% # taking min and max of dates of available data for each site and parameter combo
  unite(date_range, c("date_min", "date_max"), sep = "  -  ", remove = TRUE) %>% # uniting dates into one daterange column
  mutate(data_type = "continuous",
         source = case_match(
           station, 
           c("VIC", "UNI") ~ "USBR",
           "MRB" ~ "DWR SCRO",
           c("OH4", "MDM", "OBI") ~ "USGS",
           "MSD" ~ "DWR DISE",
           c("TPI", "GCT") ~ "DWR",
           c("HBP", "CLC", "HRO", "KA0", "TRP", "OLD", "OMR") ~ "DWR O&M",
           .default = "DWR NCRO"
         ))


# Join ----
# list of dataframes to join
cdec_list <- list(intervals_cdec, cdec_samp_count, cdec_param)

# joining dataframes in list
full_dat <- cdec_list %>% 
  reduce(left_join, by = c("parameter", "station"))
  
  
  
# Export -------
write_csv(full_dat, here("Data","Data_clean","cdec_data_long.csv"))


          