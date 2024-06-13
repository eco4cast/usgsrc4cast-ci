FROM rocker/binder:latest

# Ensure the commands are run as root user
USER root

# Update the package list and install required packages
RUN rm -rf /var/lib/apt/lists/* && \
    apt-get update && \
    apt-get -y install cron jags libgd-dev libnetcdf-dev python3 python3-pip && \
    apt-get clean && \
    sudo update-ca-certificates

# Install R packages
RUN install2.r devtools remotes reticulate

# Install R packages from GitHub
RUN R -e "remotes::install_github('cboettig/minioclient')" && \
    R -e "remotes::install_github('eco4cast/stac4cast')" && \
    R -e "remotes::install_github('eco4cast/EFIstandards')" && \
    R -e "remotes::install_github('cboettig/aws.s3')" && \
    R -e "remotes::install_github('eco4cast/score4cast')" && \
    R -e "remotes::install_github('EcoForecast/ecoforecastR')" && \
    R -e "remotes::install_github('eco4cast/neon4cast')" && \
    R -e "remotes::install_github('cboettig/prov')" && \
    R -e "remotes::install_github('eco4cast/read4cast')" && \
    R -e "remotes::install_github('eco4cast/gefs4cast')" && \
    R -e "remotes::install_github('mitchelloharawild/distributional', ref = 'bb0427e')"

# Install additional R packages
RUN install2.r arrow renv rjags neonstore ISOweek RNetCDF fable fabletools forecast imputeTS duckdbfs gsheet && \
    install2.r ncdf4 scoringRules tidybayes tidync udunits2 bench contentid yaml RCurl here feasts future furrr jsonlite

# Copy cron script
COPY cron.sh /etc/services.d/cron/run

# Switch back to the default user if necessary
# USER ${NB_USER}
