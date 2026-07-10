# R Code to download and process south delta continuous wq station data
# Created by: Nick Framsted (nframsted@usgs.gov)
# Date Created: 4/16/24
# Date Last Modified: 05/06/24

## LIBRARIES ----------
library(tidyverse)
library(lubridate)
library(scales)
library(gt)
library(data.table)
library(ggplot2)

theme_set(theme_bw())


## Continuous data CNRA download URLS -----------
# downloading entire station trace download links csv from CNRA website

# data from link provided by DWR in "period_of_record" sheet in "period_of_record.xlsx" (https://cawater.sharepoint.com/:x:/r/teams/DWR-EXT-PROJ-SDPOG/Shared%20Documents/HABs/USGS-WO/Task1-Compile-Integrate-NCRO-CHAB/DataInventoryTables/period_of_record.xlsx?d=w2984b8d135fa4010ad822bd3d8947d36&csf=1&web=1&e=qjsyV7)

wdl_data_links <- read_csv("https://data.cnra.ca.gov/dataset/fcba3a88-a359-4a71-a58c-6b0ff8fdc53f/resource/cdb5dd35-c344-4969-8ab2-d0e2d6c00821/download/station-trace-download-links.csv")


glimpse(wdl_data_links)

# list of parameters available
unique(wdl_data_links$parameter)






### 1. Filtering data download links ---------
# filtering data by which sites and parameters we are interested in
# need to create dataframes for each parameter and then join them by timestamp


# vector of station IDs of interest in south delta
SD_WQ_stations <- c("B9541050", "B9541000", "B9541500", "B9539000", "B9576000", "B9528500", "B9529500", "B9532000", "B9550600", "B9553100", "B9554100", "B9536500", "B9537000", "B9537800", "B9540000", "B9542100", "B9534100", "B9533800", "B9532500", "B9530000", "B9550000", "B9536600", "B9541050")

SD_flow_stations <- c("B95320", "B95338", "B95341", "B95370Q", "B95380Q", "B95390", "B95400Q", "B95410Q", "B95415Q", "B95502", "B95541", "B95760", "B95765Q", "B95820Q")

# vector of parameters of interest
params <- c("Air Temperature", "Chlorophyll", "DissolvedOxygen", "DissolvedOxygenPercentage", "ECat25C", "StreamFlow", "fDOM", "pH", "Salinity", "Turbidity", "Velocity", "WaterSurfaceElevationNAVD88", "WaterTemp", "WaterTempADCP")





# df of all wdl links to csv files for all sites and parameters we're interested in
wdl_data_links2 <- wdl_data_links %>% 
  filter(station_number %in% c(SD_WQ_stations, SD_flow_stations)
         & parameter %in% params 
         & output_interval == "RAW"
         ) %>% 
  mutate(parameter_R = gsub(" ", "_", parameter)) # creating new R-friendly parameter names by removing spaces and replacing with underscores. This so that I can use a vector of these parameter names in a for loop.


#station_number %in% SD_stations &





# vector of parameter names for for loop below
parameters <- unique(wdl_data_links2$parameter_R)

# there is no flow or river stage data at these sites on this database!





# for loop to create a dataframe for each parameter
for (i in parameters) {
  # filtering data links by parameter
  x <- wdl_data_links2 %>% 
    filter(parameter_R == i) %>% 
    pull(download_link)
  
  # reading in csv links for each parameter, then binding rows 
  y <- x %>% set_names() %>% 
  map_dfr(  ~ read_csv(., skip = 3, 
             col_names = FALSE,
             col_types = "cddc"),
             .id = "file_name")

  #Add column names
  names(y) <- c("file_name","DateTime","val","qual","meta") 
  
  #Parse DateTime, filter for CY 2023 data, fill any DateTime gaps.
  z <- y %>% 
    mutate(DateTime = mdy_hms(DateTime),
           Year = year(DateTime),
           Month = month(DateTime),
           #DT = floor_date(DateTime, unit = "minute"), # saving as new column and leaving DateTime column intact to investigate possible duplicate rows
           DT = floor_date(DateTime, unit = "minute"), # function corrects datetime when seconds are not on the 00 mark
           parameter = i) %>%
    group_by(file_name) %>% # grouping by site (i.e. file_name) and filling in missing timestamps for each site individually
  complete(DT = seq.POSIXt(min(DateTime), 
                                 max(DateTime), 
                                 by = "15 min")) 
    #group_by(DateTime, file_name, meta, Year, Month, parameter) %>% # grouping to get rid of multiple data points per datetime
    #summarise(value = if_else(qual == 1 | qual == 2, median(val, na.rm = TRUE), NA), # taking average value if good quality data
            #qual = if_else(qual == 1 | qual == 2, max(qual , na.rm = TRUE), NA), # taking the max of qual to have a conservative estimate of what the data quality was
            #.groups = "drop") # dropping groupings in resulting dataframe
  
  #Use substring to assign new columns with Station and parameter codes from file_name column
  z$Station = sub(".*?/wdlcontinuous/([^/]+)/.*", "\\1", z$file_name)
  
  assign(paste0(i, "_data"), z)
}





### 2. Joining WDL data ------------
# joining dataframes of each parameter created above

# creating a list of dataframes to join
wq_list <- list(Chlorophyll_data, DissolvedOxygen_data, DissolvedOxygenPercentage_data, ECat25C_data, pH_data, Salinity_data, StreamFlow_data, Turbidity_data, Velocity_data, WaterSurfaceElevationNAVD88_data, WaterTemp_data, WaterTempADCP_data)


# joining dataframes
# data in long format (one observation per row)
wq_dat <- wq_list %>% 
  bind_rows()





##### Archive code ----------
# used this when investigating multiple measuremnts per datetime per site in data, resolved this
# need to un-comment DT in mutate function of for loop to get this to work


# investigating multiple values that are not uniquely identifiable when pivotting wider. That means the data has multiple vals that have identical rows (duplicates)
dups <- wq_dat %>%
  dplyr::group_by(DT, file_name, meta, Year, Month, Station, parameter) %>%
  dplyr::summarise(n = dplyr::n(), .groups = "drop") %>%
  dplyr::filter(n > 1L)





# site with multiple measurements for a single value of DT-- may need to average these or take median so that there's one measurement per DT per site
dups1 <- wq_dat %>% 
  filter(Station == "B9554100" & DT == ymd_hms("2004-09-10 09:24:00
") & parameter == "Dissolved_Oxygen_Percentage")
# looks like they're all quality values (qual = 1), I will take a median parameter value of all duplicate rows before pivotting wider


#dups1_check <- wq_dat_no_dups %>% 
  #filter(Station == "B9554100" & DT == ymd_hms("2004-09-10 09:24:00
#") & parameter == "Dissolved_Oxygen_Percentage")

# looks good, the four data points are summarised by the correct median and qual code










### 3. Pivot from long to wide format-------
# pivotting data from long to wide format (multiple obs per row by datetime)
# there are sometimes multiple measurements per minute for a specific site, likely due to a burst measurement-- we may need to average or take median of these measurements so that we have one value per minute

## can take values with a qual code of 1 that indicates a high quality measurement, and if there are multiple then take the average/median
wq_dat_no_dups_dplyr <- wq_dat %>% 
  group_by(DT, Year, Month, parameter, Station) %>% # grouping to get rid of multiple data points per datetime
    summarise(value = median(val, na.rm = TRUE),
              qual = max(qual, na.rm = TRUE),
      
      #value = if_else(qual == 1 | qual == 2, median(val, na.rm = TRUE), NA), # taking average value if good quality data
            #qual = if_else(qual == 1 | qual == 2, max(qual , na.rm = TRUE), NA), # taking the max of qual to have a conservative estimate of what the data quality was
            .groups = "drop") # dropping groupings in resulting dataframe






# use data.table library to summarise function
# putting data into data.table format
wq_dat_dt <- data.table(wq_dat)

# calculating median for values for the same datetime (DT) and recording the number of measurements aggregated during this step in the "sample_count" column
wq_dat_no_dups <- wq_dat_dt[, .(sample_count = .N, val = median(val, na.rm = TRUE), qual = max(qual, na.rm = TRUE)),
                         by = .(DT, Year, Month, parameter, Station)]



# exploring NAs
#wq_dat %>% 
  #filter(Station == "B9576000" & DT == "2024-03-23 11:30:08")

# pivotting wider
wq_dat_wide <- wq_dat_no_dups %>%
  tibble() %>% 
  select(-sample_count) %>% 
  pivot_wider(values_from = c(val, qual), names_from = parameter)








### 4. Plotting data ----------
wq_dat %>% 
  filter(parameter == "Chlorophyll") %>% 
  ggplot(aes(x = DateTime, y = val)) +
  geom_point() +
  geom_line()+
  facet_wrap(~Station)





### 5. Calculating Daily Averages --------
da_dat <- wq_dat %>% 
  mutate(date = date(DateTime),
         nan = as.numeric(case_when(
           !is.na(val) ~ 1,
           .default = 0
         ))) %>% 
  group_by(Station, parameter, date) %>% 
  summarise(count_by_sitedate = sum(nan),
            #calculate daily average and median for days with >50 samples
            daily_avg = mean(val[count_by_sitedate >= 50], na.rm = TRUE),
            daily_med = median(val[count_by_sitedate >= 50], na.rm = TRUE),
            daily_sd = sd(val[count_by_sitedate >= 50], na.rm = TRUE)) %>% 
  ungroup()
  



### 6. Export data ------------
# saving data as rds files
# long format
saveRDS(wq_dat, "Data/Data_clean/continuous_station_data_long.rds")


# read in data
wq_dat <- readRDS("Data/Data_clean/continuous_station_data_long.rds")



# wide format in csv
write_csv(wq_dat_wide, "Data/Data_clean/continuous_station_data_wide.csv")


# daily avg data in csv
write_csv(da_dat, "Data/Data_clean/continuous_station_data_long_daily_avg.csv")





## Discrete Data Download from CNRA website ----------
raw_discrete <- read_csv("https://data.cnra.ca.gov/dataset/3f96977e-2597-4baa-8c9b-c433cea0685e/resource/a9e7ef50-54c3-4031-8e44-aa46f3c660fe/download/lab_results.csv")



### 1. Clean data -------
# Parse date times and filter parameter. R.L. data is reported at the reporting limit.
df_discrete <- raw_discrete %>% mutate(sample_date = mdy_hm(sample_date), Date = date(sample_date), Year = year(sample_date), result_num = as.numeric(result), result_num = case_when(result == "< R.L." ~ reporting_limit, TRUE ~ result_num))

### 2. Exporting full discrete data --------
saveRDS(df_discrete, "Data/Data_clean/discrete_data.rds")

df_discrete <- read_rds("Data/Data_clean/discrete_data.rds")


### 2. Filtering sites and parameters of interest ----------
# vector of station numbers I need
# got these from the "DataDictionary_draft.xlsx" : https://cawater.sharepoint.com/teams/DWR-EXT-PROJ-SDPOG/Shared%20Documents/Forms/AllItems.aspx?sw=bypass&bypassReason=abandoned&id=%2Fteams%2FDWR%2DEXT%2DPROJ%2DSDPOG%2FShared%20Documents%2FHABs%2FUSGS%2DWO%2FTask1%2DCompile%2DIntegrate%2DNCRO%2DCHAB%2FData&viewid=21efa1d2%2D45b5%2D415a%2D943c%2D2d05cce21be0

discrete_station_ids <- c("B9D74911256", "B9D74921269", "B9D72921327", "B9D74921261", "B9D75261230", "B9D75011230", "B9D75291280", "B9D75351292", "B9536600", "B9536500", "B9D74851200", "B9D74971332", "B9537000", "B9D74871232", "B9D74811247", "B9D74811224", "B9D74761253", "B9D74821274", "B9D75231318", "B9D74991332")

discrete_params <- c(params, "Pheophytin a", "Dissolved Ammonia", "Dissolved Nitrate + Nitrite", "Dissolved Organic Carbon", "Dissolved Organic Nitrogen", "Dissolved Total Kjeldahl Nitrogen", "Dissolved ortho-Phosphate", "Chlorophyll a", "Total Kjeldahl Nitrogen", "Total Organic Carbon", "Total Phosphorus", "Total Suspended Solids", "Turbidity", "Volatile Suspended Solids", "Specific Conductance", "Total Alkalinity", "Total Organic Nitrogen", "Total Ammonia", "Dissolved Nitrate")



# Parse date times and filter for station IDs and parameter. R.L. data is reported at the reporting limit.
df_discrete2 <- df_discrete %>% 
  filter(station_number %in% discrete_station_ids & parameter %in% discrete_params)




# exporting just south delta stations and parameters of interest
saveRDS(df_discrete2, "Data/Data_clean/south_delta_stations_discrete_data.rds")

df_discrete2 <- read_rds("Data/Data_clean/south_delta_stations_discrete_data.rds")






## Field Results download from CNRA website ---------
raw_field <- read_csv("https://data.cnra.ca.gov/dataset/3f96977e-2597-4baa-8c9b-c433cea0685e/resource/1911e554-37ab-44c0-89b0-8d7044dd891d/download/field_results.csv")



### 1. Parse date times ---------
df_field <- raw_field %>% 
  mutate(Date = date(sample_date), Year = year(sample_date)) 


### 2. export full field data ---------
saveRDS(df_field, "Data/Data_clean/field_data.rds")

df_field <- read_rds("Data/Data_clean/field_data.rds")


### 3. filtering sites and parameters of interest -------
df_field2 <- df_field %>% 
  filter(station_number %in% discrete_station_ids) %>%
  filter(parameter %in% discrete_params)


# exporting just south delta stations and parameters of interest
saveRDS(df_field2, "Data/Data_clean/south_delta_stations_field_data.rds")


df_field2 <- read_rds("Data/Data_clean/south_delta_stations_field_data.rds")




# lat longs from CDEC ( or email elena & jared) ------------
lat_long <- df_discrete2 %>%
  distinct(latitude, longitude, station_number)

lat_long2 <- df_field2 %>% 
  distinct(latitude, longitude, station_number)


# table of continuous station lat/longs
# link from: https://data.cnra.ca.gov/dataset/dwr-continuous-data-download-links/resource/c2b08f48-acfd-4a5b-9799-0f3e07d83192
lat_longs_cont <- read_csv("https://data.cnra.ca.gov/dataset/fcba3a88-a359-4a71-a58c-6b0ff8fdc53f/resource/c2b08f48-acfd-4a5b-9799-0f3e07d83192/download/stations.csv") %>% 
  filter(station_number %in% SD_stations) %>% 
  distinct(latitude, longitude, station_number, station)


# joining continuous and discrete site lat/longs
lat_long_all <- bind_rows(list(discrete = lat_long, continuous = lat_longs_cont), .id = "id")


### 1. Export -------
write_csv(lat_long_all, "Data/Data_clean/station_lat_long.csv")