#renv::restore()

print(paste0("Running Creating Aquatics baselines at ", Sys.time()))


print(paste0("Running daily climatology at ", Sys.time()))
source("baseline_models/models/aquatics_climatology.R")
print(paste0("Completed daily climatology ", Sys.time()))

print(paste0("Running daily persistence at ", Sys.time()))
source("baseline_models/models/aquatics_persistenceRW.R")
print(paste0("Completed daily persistence ", Sys.time()))

# TODO: not  sure what this is here for
RCurl::url.exists("https://hc-ping.com/a848914e-9abf-45e4-bcf3-27f570cc3623")
